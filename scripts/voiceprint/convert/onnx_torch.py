"""Run an ONNX graph as a traceable torch.nn.Module (for Core ML conversion).

A small interpreter, not a general ONNX runtime: it covers the ops in the
bake-off's speaker networks (WeSpeaker ResNets, NeMo TitaNet, 3D-Speaker CAM++).
The point is that `torch.jit.trace` records a graph whose only dynamic dimension
(time) stays dynamic:

  * Shape-like int tensors (Shape -> Gather -> Concat -> Reshape chains) are kept as
    `ShapeList`, a Python list whose items are ints or traced 0-dim tensors. Under
    tracing `x.shape[i]` is a 0-dim tensor, so arithmetic on it is recorded.
  * Static constants stay numpy until they meet a tensor.
  * Weights become buffers.

Unsupported ops raise NotImplementedError with the op name.
"""
from __future__ import annotations

import re
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

INT64_MAX = 2 ** 62


class ShapeList(list):
    """A dynamic 1-D int64 tensor held as a list of ints / traced 0-dim tensors."""


def _is_shapeish(v):
    return isinstance(v, ShapeList) or (isinstance(v, np.ndarray) and v.dtype.kind in "iu")


def _scalar_ish(v):
    return isinstance(v, (int, float)) or (isinstance(v, torch.Tensor) and v.dim() == 0 and not v.is_floating_point())


def _to_list(v):
    if isinstance(v, ShapeList):
        return list(v)
    if isinstance(v, np.ndarray):
        return [int(i) for i in v.reshape(-1)]
    if isinstance(v, torch.Tensor):
        if v.dim() == 0:
            return [v]
        return [v[i] for i in range(v.shape[0])]
    if isinstance(v, (list, tuple)):
        return list(v)
    return [v]


_NP2TORCH = {1: torch.float32, 6: torch.int32, 7: torch.int64, 9: torch.bool, 10: torch.float16, 11: torch.float64}


class OnnxModule(nn.Module):
    def __init__(self, path: str | Path, outputs: list | None = None):
        super().__init__()
        import onnx
        from onnx import numpy_helper

        model = onnx.load(str(path))
        g = model.graph
        self.input_names = [i.name for i in g.input if i.name not in {x.name for x in g.initializer}]
        self.output_names = list(outputs) if outputs else [o.name for o in g.output]
        self._consts: dict[str, np.ndarray] = {}
        self._buf: dict[str, str] = {}
        uses = {}
        for n in g.node:
            for i in n.input:
                uses.setdefault(i, []).append(n.op_type)
        for init in g.initializer:
            arr = numpy_helper.to_array(init).copy()
            if arr.dtype.kind == "f" and arr.size > 16:
                safe = "w_" + re.sub(r"[^A-Za-z0-9_]", "_", init.name)
                self.register_buffer(safe, torch.from_numpy(arr.astype(np.float32)))
                self._buf[init.name] = safe
            else:
                self._consts[init.name] = arr
        self.nodes = []
        for n in g.node:
            attrs = {}
            for a in n.attribute:
                v = onnx.helper.get_attribute_value(a)
                if hasattr(v, "dims"):
                    v = numpy_helper.to_array(v).copy()
                elif isinstance(v, bytes):
                    v = v.decode()
                elif isinstance(v, list) and v and isinstance(v[0], bytes):
                    v = [x.decode() for x in v]
                attrs[a.name] = v
            if n.op_type == "Constant":
                val = attrs.get("value")
                if val is None:
                    for k in ("value_float", "value_int", "value_floats", "value_ints"):
                        if k in attrs:
                            val = np.array(attrs[k])
                self._consts[n.output[0]] = np.asarray(val)
                continue
            self.nodes.append((n.op_type, list(n.input), list(n.output), attrs, n.name))
        # keep only nodes the requested outputs depend on
        need = set(self.output_names)
        keep = []
        for node in reversed(self.nodes):
            if any(o in need for o in node[2]):
                keep.append(node)
                need.update(i for i in node[1] if i)
        self.nodes = list(reversed(keep))
        self.input_names = [i for i in self.input_names if i in need]

    # ------------------------------------------------------------------ helpers
    def _get(self, env, name):
        if name == "":
            return None
        if name in env:
            return env[name]
        if name in self._buf:
            return getattr(self, self._buf[name])
        if name in self._consts:
            return self._consts[name]
        raise KeyError(name)

    @staticmethod
    def _t(v, like=None):
        """Anything -> torch tensor."""
        if isinstance(v, torch.Tensor):
            return v
        if isinstance(v, ShapeList):
            return torch.cat([torch.as_tensor(i, dtype=torch.int64).reshape(1) if not isinstance(i, torch.Tensor)
                              else i.to(torch.int64).reshape(1) for i in v])
        if isinstance(v, np.ndarray):
            t = torch.from_numpy(np.ascontiguousarray(v))
            if like is not None and like.is_floating_point() and t.is_floating_point():
                t = t.to(like.dtype)
            return t
        if isinstance(v, (int, float, bool)):
            return torch.tensor(v)
        raise TypeError(type(v))

    # ------------------------------------------------------------------ forward
    def forward(self, *inputs):
        env = {}
        for name, v in zip(self.input_names, inputs):
            env[name] = v
        for op, ins, outs, attrs, nname in self.nodes:
            args = [self._get(env, i) for i in ins]
            fn = getattr(self, f"op_{op}", None)
            if fn is None:
                raise NotImplementedError(f"ONNX op {op} ({nname})")
            res = fn(args, attrs)
            if not isinstance(res, (list, tuple)) or isinstance(res, ShapeList):
                res = [res]
            for o, r in zip(outs, res):
                env[o] = r
        outs = [env[o] for o in self.output_names]
        return outs[0] if len(outs) == 1 else tuple(outs)

    # ------------------------------------------------------------------ ops
    def op_Identity(self, a, at):
        return a[0]

    def op_Conv(self, a, at):
        x, w = a[0], self._t(a[1])
        b = self._t(a[2]) if len(a) > 2 and a[2] is not None else None
        nd = w.dim() - 2
        strides = at.get("strides", [1] * nd)
        dil = at.get("dilations", [1] * nd)
        group = at.get("group", 1)
        pads = at.get("pads", [0] * (2 * nd))
        if at.get("auto_pad", "NOTSET") not in ("NOTSET", ""):
            raise NotImplementedError("Conv auto_pad")
        sym = all(pads[i] == pads[i + nd] for i in range(nd))
        conv = F.conv1d if nd == 1 else F.conv2d
        if sym:
            return conv(x, w, b, strides, pads[:nd], dil, group)
        # asymmetric: explicit pad (torch pad order is last dim first)
        tp = []
        for i in reversed(range(nd)):
            tp += [pads[i], pads[i + nd]]
        return conv(F.pad(x, tp), w, b, strides, 0, dil, group)

    def op_Relu(self, a, at):
        return torch.relu(a[0])

    def op_Sigmoid(self, a, at):
        return torch.sigmoid(a[0])

    def op_Tanh(self, a, at):
        return torch.tanh(a[0])

    def op_Softmax(self, a, at):
        return torch.softmax(a[0], dim=at.get("axis", -1))

    def op_Sqrt(self, a, at):
        return torch.sqrt(a[0])

    def op_Abs(self, a, at):
        return torch.abs(a[0])

    def op_Neg(self, a, at):
        return -a[0]

    def op_Exp(self, a, at):
        return torch.exp(a[0])

    def op_Log(self, a, at):
        return torch.log(a[0])

    def op_Not(self, a, at):
        return torch.logical_not(a[0])

    def op_Clip(self, a, at):
        x = a[0]
        lo = at.get("min") if len(a) < 2 or a[1] is None else a[1]
        hi = at.get("max") if len(a) < 3 or a[2] is None else a[2]
        lo = None if lo is None else float(np.asarray(lo)) if not isinstance(lo, torch.Tensor) else lo
        hi = None if hi is None else float(np.asarray(hi)) if not isinstance(hi, torch.Tensor) else hi
        if isinstance(x, torch.Tensor) and x.is_floating_point() and lo == 0.0 and hi is not None and hi >= 1e4:
            return torch.relu(x)  # hardtanh-style clip that never binds: plain ReLU for Core ML
        return torch.clamp(x, min=lo, max=hi)

    def _binary(self, a, fn_py, fn_t):
        x, y = a[0], a[1]
        # pure shape arithmetic stays symbolic
        if (_is_shapeish(x) or _scalar_ish(x)) and (_is_shapeish(y) or _scalar_ish(y)) and not (
                isinstance(x, np.ndarray) and isinstance(y, np.ndarray)):
            xs, ys = _to_list(x), _to_list(y)
            if len(xs) == 1 and len(ys) > 1:
                xs = xs * len(ys)
            if len(ys) == 1 and len(xs) > 1:
                ys = ys * len(xs)
            out = [fn_py(p, q) for p, q in zip(xs, ys)]
            scalar = all(_scalar_ish(v) or (isinstance(v, np.ndarray) and v.ndim == 0) for v in (x, y))
            return out[0] if scalar else ShapeList(out)
        if not isinstance(x, (torch.Tensor, ShapeList)) and not isinstance(y, (torch.Tensor, ShapeList)):
            return np.asarray(fn_py(np.asarray(x), np.asarray(y)))
        like = x if isinstance(x, torch.Tensor) else (y if isinstance(y, torch.Tensor) else None)
        tx = self._t(x, like) if not isinstance(x, (int, float)) else x
        ty = self._t(y, like) if not isinstance(y, (int, float)) else y
        return fn_t(tx, ty)

    def op_Add(self, a, at):
        return self._binary(a, lambda p, q: p + q, torch.add)

    def op_Sub(self, a, at):
        return self._binary(a, lambda p, q: p - q, torch.sub)

    def op_Mul(self, a, at):
        return self._binary(a, lambda p, q: p * q, torch.mul)

    def op_Div(self, a, at):
        def py(p, q):
            if isinstance(p, np.ndarray) and p.dtype.kind in "iu":
                return p // q
            if isinstance(p, float) or isinstance(q, float) or (isinstance(p, torch.Tensor) and p.is_floating_point()):
                return p / q
            return p // q

        def t(p, q):
            if not p.is_floating_point() and not (isinstance(q, torch.Tensor) and q.is_floating_point()):
                return torch.div(p, q, rounding_mode="trunc")
            return p / q

        return self._binary(a, py, t)

    def op_Pow(self, a, at):
        x, y = a[0], a[1]
        if isinstance(y, np.ndarray) and y.size == 1:
            e = float(y.reshape(-1)[0])
            if e == 2.0:
                return x * x
            if e == 0.5:
                return torch.sqrt(x)
            return torch.pow(x, e)
        return torch.pow(self._t(x), self._t(y, x))

    def op_Equal(self, a, at):
        return self._binary(a, lambda p, q: p == q, torch.eq)

    def op_Less(self, a, at):
        return self._binary(a, lambda p, q: p < q, torch.lt)

    def op_Greater(self, a, at):
        return self._binary(a, lambda p, q: p > q, torch.gt)

    def op_Where(self, a, at):
        c, x, y = a
        c = self._t(c)
        like = x if isinstance(x, torch.Tensor) and x.is_floating_point() else (
            y if isinstance(y, torch.Tensor) else None)
        return torch.where(c.bool(), self._t(x, like), self._t(y, like))

    def op_Cast(self, a, at):
        x = a[0]
        to = _NP2TORCH.get(at["to"])
        if to is None:
            raise NotImplementedError(f"Cast to {at['to']}")
        if isinstance(x, ShapeList):
            if to in (torch.int64, torch.int32):
                return x
            return self._t(x).to(to)
        if isinstance(x, np.ndarray):
            return x.astype({torch.float32: np.float32, torch.int64: np.int64, torch.int32: np.int32,
                             torch.bool: np.bool_, torch.float16: np.float16, torch.float64: np.float64}[to])
        if isinstance(x, (int, float)):
            return float(x) if to.is_floating_point else int(x)
        if to == torch.float64:
            to = torch.float32
        if to == torch.int32:
            to = torch.int64
        return x.to(to)

    def op_Shape(self, a, at):
        x = a[0]
        if isinstance(x, ShapeList):
            return np.array([len(x)], dtype=np.int64)
        if isinstance(x, np.ndarray):
            return np.array(x.shape, dtype=np.int64)
        return ShapeList([x.shape[i] for i in range(x.dim())])

    def op_Gather(self, a, at):
        x, idx = a
        axis = at.get("axis", 0)
        if isinstance(x, (ShapeList, np.ndarray)) and isinstance(idx, np.ndarray) and (
                isinstance(x, ShapeList) or x.ndim == 1):
            items = _to_list(x) if isinstance(x, ShapeList) else list(x)
            if idx.ndim == 0:
                return items[int(idx)]
            return ShapeList([items[int(i)] for i in idx.reshape(-1)])
        if isinstance(idx, np.ndarray):
            if idx.ndim == 0:
                return torch.select(self._t(x), axis, int(idx))
            it = torch.from_numpy(idx.astype(np.int64))
            t = self._t(x)
            if idx.ndim == 1 and np.all(np.diff(idx) == 1) and idx[0] >= 0:
                sl = [slice(None)] * t.dim()
                sl[axis] = slice(int(idx[0]), int(idx[-1]) + 1)
                return t[tuple(sl)]
            return torch.index_select(t, axis, it.reshape(-1)).reshape(
                list(t.shape[:axis]) + list(idx.shape) + list(t.shape[axis + 1:]))
        raise NotImplementedError("Gather with dynamic indices")

    def op_Unsqueeze(self, a, at):
        x = a[0]
        axes = at.get("axes")
        if axes is None:
            axes = [int(i) for i in np.asarray(a[1]).reshape(-1)]
        if _scalar_ish(x) and axes == [0]:
            return ShapeList([x])
        if isinstance(x, np.ndarray):
            return np.expand_dims(x, tuple(axes))
        t = self._t(x)
        out_rank = t.dim() + len(axes)
        for ax in sorted(ax % out_rank for ax in axes):
            t = t.unsqueeze(ax)
        return t

    def op_Squeeze(self, a, at):
        x = a[0]
        axes = at.get("axes")
        if axes is None and len(a) > 1 and a[1] is not None:
            axes = [int(i) for i in np.asarray(a[1]).reshape(-1)]
        if isinstance(x, ShapeList) and len(x) == 1:
            return x[0]
        if isinstance(x, np.ndarray):
            return np.squeeze(x, axis=tuple(axes) if axes else None)
        if axes is None:
            return torch.squeeze(x)
        for ax in sorted((ax % x.dim() for ax in axes), reverse=True):
            x = x.squeeze(ax)
        return x

    def op_Concat(self, a, at):
        axis = at["axis"]
        if all(_is_shapeish(v) or _scalar_ish(v) for v in a) and any(isinstance(v, ShapeList) for v in a):
            out = []
            for v in a:
                out += _to_list(v)
            return ShapeList(out)
        if all(isinstance(v, np.ndarray) for v in a):
            return np.concatenate(a, axis=axis)
        like = next(v for v in a if isinstance(v, torch.Tensor))
        return torch.cat([self._t(v, like) for v in a], dim=axis)

    def _shape_arg(self, x, shape):
        dims = _to_list(shape)
        out = []
        for i, d in enumerate(dims):
            if isinstance(d, int) and d == 0:
                out.append(x.shape[i])
            else:
                out.append(d)
        return out

    def op_Reshape(self, a, at):
        x, shape = a
        if isinstance(x, np.ndarray) and isinstance(shape, np.ndarray):
            return x.reshape(shape)
        return self._t(x).reshape(self._shape_arg(x, shape))

    def op_Flatten(self, a, at):
        axis = at.get("axis", 1)
        x = a[0]
        if axis == 0:
            return x.reshape(1, -1)
        if axis > 1:
            x = x.flatten(0, axis - 1)
        return x.flatten(start_dim=1)

    def op_Transpose(self, a, at):
        return a[0].permute(*at["perm"])

    def op_Expand(self, a, at):
        x, shape = a
        t = self._t(x)
        dims = _to_list(shape)
        if len(dims) == t.dim():
            target = []
            for i, d in enumerate(dims):
                if isinstance(d, int) and d == 1:
                    target.append(-1)
                else:
                    target.append(d)
            return t.expand(*target)
        return t * torch.ones(dims, dtype=t.dtype)

    def op_Tile(self, a, at):
        return self._t(a[0]).repeat(*_to_list(a[1]))

    def op_ConstantOfShape(self, a, at):
        val = at.get("value", np.array([0.0], dtype=np.float32))
        v = np.asarray(val).reshape(-1)[0]
        dims = _to_list(a[0])
        if isinstance(a[0], np.ndarray):
            return np.full([int(d) for d in dims], v)
        dt = torch.float32 if np.asarray(val).dtype.kind == "f" else (
            torch.bool if np.asarray(val).dtype.kind == "b" else torch.int64)
        return torch.full(dims, v.item(), dtype=dt)

    def op_Range(self, a, at):
        start, limit, delta = [(_to_list(v)[0] if not _scalar_ish(v) else v) for v in a]
        if all(isinstance(v, np.ndarray) or isinstance(v, (int, np.integer)) for v in (start, limit, delta)):
            return np.arange(int(start), int(limit), int(delta))
        return torch.arange(start, limit, delta)

    def op_Slice(self, a, at):
        x = a[0]
        starts, ends = _to_list(a[1]), _to_list(a[2])
        axes = _to_list(a[3]) if len(a) > 3 and a[3] is not None else list(range(len(starts)))
        steps = _to_list(a[4]) if len(a) > 4 and a[4] is not None else [1] * len(starts)
        if isinstance(x, ShapeList):
            assert axes == [0]
            s, e, st = starts[0], ends[0], steps[0]
            e = None if isinstance(e, int) and e >= INT64_MAX else e
            return ShapeList(list(x)[s:e:st])
        if isinstance(x, np.ndarray) and any(isinstance(v, torch.Tensor) for v in starts + ends):
            x = torch.from_numpy(np.ascontiguousarray(x))  # dynamic bounds: keep it in the trace
        rank = x.dim() if isinstance(x, torch.Tensor) else x.ndim
        sl = [slice(None)] * rank
        for s, e, ax, st in zip(starts, ends, axes, steps):
            if isinstance(e, int) and e >= INT64_MAX:
                e = None
            if isinstance(s, int) and s == 0:
                s = None
            sl[int(ax)] = slice(s, e, int(st))
        return x[tuple(sl)]

    def op_ReduceMean(self, a, at):
        x = a[0]
        axes = at.get("axes") if "axes" in at else (_to_list(a[1]) if len(a) > 1 else None)
        keep = bool(at.get("keepdims", 1))
        if axes is None:
            return x.mean() if not keep else x.mean(dim=list(range(x.dim())), keepdim=True)
        return x.mean(dim=[int(i) for i in axes], keepdim=keep)

    def op_ReduceSum(self, a, at):
        x = a[0]
        axes = at.get("axes") if "axes" in at else (_to_list(a[1]) if len(a) > 1 and a[1] is not None else None)
        keep = bool(at.get("keepdims", 1))
        if not isinstance(x, torch.Tensor):
            x = self._t(x)
        if x.dtype == torch.bool:
            x = x.to(torch.int64)
        if axes is None:
            return x.sum() if not keep else x.sum(dim=list(range(x.dim())), keepdim=True)
        return x.sum(dim=[int(i) for i in axes], keepdim=keep)

    def op_ReduceProd(self, a, at):
        x = a[0]
        keep = bool(at.get("keepdims", 1))
        if isinstance(x, (ShapeList, np.ndarray)):
            items = _to_list(x)
            p = items[0]
            for v in items[1:]:
                p = p * v
            return ShapeList([p]) if keep else p
        raise NotImplementedError("ReduceProd on tensors")

    def op_ReduceMax(self, a, at):
        x = a[0]
        axes = at.get("axes") if "axes" in at else (_to_list(a[1]) if len(a) > 1 else None)
        keep = bool(at.get("keepdims", 1))
        return torch.amax(x, dim=[int(i) for i in axes], keepdim=keep)

    def op_MatMul(self, a, at):
        return torch.matmul(self._t(a[0]), self._t(a[1]))

    def op_Gemm(self, a, at):
        x, w = self._t(a[0]), self._t(a[1])
        if at.get("transA", 0):
            x = x.t()
        if at.get("transB", 0):
            w = w.t()
        y = torch.matmul(x, w) * float(at.get("alpha", 1.0))
        if len(a) > 2 and a[2] is not None:
            y = y + self._t(a[2]) * float(at.get("beta", 1.0))
        return y

    def op_BatchNormalization(self, a, at):
        x, sc, b, m, v = [self._t(t) for t in a[:5]]
        eps = float(at.get("epsilon", 1e-5))
        return F.batch_norm(x, m, v, sc, b, False, 0.0, eps)

    def op_AveragePool(self, a, at):
        x = a[0]
        k = at["kernel_shape"]
        s = at.get("strides", [1] * len(k))
        pads = at.get("pads", [0] * (2 * len(k)))
        ceil = bool(at.get("ceil_mode", 0))
        cip = bool(at.get("count_include_pad", 0))
        if not any(pads):
            # identical in torch when there is no padding (a ceil_mode overhang is never
            # counted), and it makes Core ML exclude the overhang from the divisor too
            cip = False
        if len(k) == 1:
            return F.avg_pool1d(x, k[0], s[0], pads[0], ceil_mode=ceil, count_include_pad=cip)
        return F.avg_pool2d(x, k, s, pads[: len(k)], ceil_mode=ceil, count_include_pad=cip)

    def op_GlobalAveragePool(self, a, at):
        x = a[0]
        return x.mean(dim=list(range(2, x.dim())), keepdim=True)
