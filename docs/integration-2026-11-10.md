# Open PR integration candidate — 2026-11-10

Draft candidate only. Main promotion needs the parent's independent full-diff review,
exact-head hosted checks, full QA bench, and resolution of owner decisions below.
No release, main promotion, original-branch update or PR cleanup is authorized here.

## Scope and provenance

Base: `8a38235eef00816a79daa1324387a21ef880204d` (freshly fetched origin/main before assembly).
Branch: `codex/integration-open-prs-20261110`.
Exactly 225 frozen PR heads are retained as ancestors: the original 198 plus the
explicitly authorized 27-head expansion (#2531–#2557). No frozen PR was omitted.
The original 198 provenance/hash and entries are preserved. The dated
[expansion manifest](integration-2026-11-10-expansion-27.json) omits bodies and private
proof details; its SHA-256 and the original additional-input SHA-256 are in the ledger.
No arrivals after #2557 are added.
See [machine-readable ledger](integration-2026-11-10-manifest.json) for exact heads,
14 base-branch dependencies, changed paths, merge commits and every conflict resolution.
The manifest omits PR bodies, private proof paths, credentials and user data.

PR #2336 was integrated first. Remaining heads were merged in increasing PR order,
which respects the manifest's dependency graph. Each merge uses the exact frozen
head and retains original contributor history. Integration merges are authored and
committed by r3dbars. Textually clean merges are inclusion evidence, not correctness proof.
Later focused successors override broad-audit wording where code establishes the
current behavior; no blanket ours/theirs merge strategy was used.

## Owner decisions still pending

- #2376: the exact README privacy wording is retained in
  [a proposal](proposals/readme-privacy-2026-11-10.md); active README wording is restored.
  Including history does not adopt the proposed public promises.
- #2387: licensing notices remain subject to licensing review, especially the
  Parakeet metadata/README discrepancy and MCP transition notice. No broader grant is chosen.
- #2491: the candidate contains proposed Stats corruption refusal. This changes
  automatic recovery to an unavailable store pending repair/reopen. Explicit owner
  acceptance or a reviewed alternative is required before main promotion; no real
  database was inspected, repaired or migrated during assembly.
- #2482, #2499, #2500, #2503, #2508, #2518, #2519, #2521, #2525 and #2526:
  decision worksheets/API proposals remain unselected. They do not adopt deletion,
  retention, consent, focus, fallback or public-policy choices.

## Integration reconciliation

The per-PR ledger records each conflicted file and the concrete resolution.
Particularly important combinations:

- #2334 mic-loss continuation, #2465 bounded configuration teardown, #2471 listener
  delivery and #2507 observation ownership coexist. Input-node/device selection
  is unchanged by those focused changes; existing Bluetooth-default protections
  remain. No real mic, AirPods, system-audio or shutdown proof is claimed.
- #2502 keeps archiving asynchronous in tests, with explicit completion snapshots
  and producer joins. #2515's count removal does not undo those waits.
- #2484 uses asynchronous trusted input-source preparation; writes to unread state
  removed by #2336 remain absent.
- #2485 background prompt delivery keeps #2402 EOF/send-failure completion and its
  injected timeout scheduler. This composition needs focused combined runtime proof.
- #2481 preserves audio paired with skipped/colliding transcripts. #2491 preserves
  failed Stats stores. They address different storage lifecycles.
- #2333 stable capture row identity and eager sections coexist with passive refresh
  preservation (#2460) and targeted reveal (#2486). Native scroll/visual proof is pending.
- Test fixture isolation and native-account guards are preserved. Temporary HOME or
  CFFIXED_USER_HOME are not accepted as native preferences isolation.

## Validation record

Original assembly ancestry: PASS, all 198 frozen heads verified fetched and retained.
Expansion ancestry: PASS, all 225 exact frozen heads verified retained.
Build source lists: PASS. Duplicate declarations: PASS.
System-SQLite resource component: PASS, 12 control assertions and 148/148 behavior
assertions across 32 opens. This compiled actual SQLiteHandle/FilePermissions in an
owned disposable process; it did not construct the app or inspect a user database.

Additional integration fixes: the app entry comment was condensed to keep the
800-line ratchet; the QA automation environment compiler contract moved to
`scripts/dev/test-isolated-launch-environment.sh` so it stays an executable
behavior check under the stricter constructed-source-path checker. That actual
source component prints `automated` and passes; it does not launch the app.
The harness decision worksheet now records #2512 candidate retirement without
selecting an automation policy. Proposal patch trailing whitespace was removed.

Additional safe components: prompt delivery passed 48/48 assertions with zero
skips under network denial. The automation-gate component printed `automated`.
All 1,040 app-source files passed Swift syntax parsing (not typechecking).
Final changed-source pin checks pass (17 resolved pins checked).
Verifier selection identifies paste, meetings, UI, speed and real hardware work;
execution is blocked locally by the owner-profile boundary.
The initial safe static suite found retired harness paths; the corrected
standalone documentation-path check passes. The initial suite remains FAIL because of that recorded failure; later offline
checks are still running at this checkpoint. No failed initial run is rewritten
as a pass. A final clean complete quick-suite verdict is not claimed.

Independent review of `c8b80987d1c68167f1943ee0b4d4c8e6127d348a`
against the recorded base returned RED with two P2 integration findings:
the capture-list smoke retained the removed `QuietMeetingRow.isExpanded`
argument, and `check.sh full` omitted four new Swift CI checks. The follow-up
removes that obsolete argument and adds SQLite lifetime, capture-list scroll,
Claude-mod wrapper and lab-control typecheck steps to the full gate. Its owned
command-fixture tests now require all four commands and their dependency order.
The strengthened fixture passes with the corrected gate and rejects the original
gate at the missing SQLite step. Shell syntax, test-shape and diff checks pass;
SQLite again passes 12 controls and 148 behavior assertions, and all 10 Claude-mod
wrapper tests pass. These are component/contract results, not native list proof.
The reviewer traced all 244 changed Sources paths and accounted for all 47
conflicted PR entries/60 file resolutions; no other confirmed runtime regression
was found. Static review does not certify hardware, removed image evidence or
every line of retired/generated material. The parent checked the narrow fixes;
replacement-head hosted compilation/native outcomes remain pending.

Exact-head hosted outcomes remain pending.
Hosted run IDs are returned to the parent rather than claimed as completed proof. Full unfiltered fast/Core/integration suites, native GUI,
keyboard/microphone/TCC and full QA bench are not executed on the owner's profile.
No running app was quit, relaunched or rebuilt. Local app signing/distribution is
not performed. A native verifier selection alone is not a passing verifier run.

Hosted full bench uses trusted main's Swift CI workflow with the exact pushed
integration SHA in full_bench_source_sha, empty staged_update_source_sha and
run_hardware_smokes=false. Historical per-PR receipts are not union proof.

## Per-PR dispositions

All entries below are included; `ancestor` means the exact head was already
reachable when its turn was processed. See the JSON ledger for rationale,
conflicts, dependency IDs, test scope and any pending owner decision.

| PR | Frozen head | Disposition | Resolution details |
| --- | --- | --- | --- |
| #2330 | `1966364bed5c121d477cbe291fb925a82a48e4cc` | included | Exact frozen history retained; no manual conflict. |
| #2333 | `60b5ac37b7bae32502241824059f897973e0b2b9` | included | Exact frozen history retained; no manual conflict. |
| #2334 | `0c82f6a3ee6c44c6bed6624810277551984e2184` | included | Exact frozen history retained; no manual conflict. |
| #2335 | `dc9a704f7b3b2cbc069de350b1e9bcaf08ae7a8c` | included | Keep all three actual delegate extension entries: CallActivity, NextSentence, OpenScreenDiagnostics. |
| #2336 | `4f99d388896c619c93b34b8727ace3428ee68203` | included | Exact frozen history retained; no manual conflict. |
| #2337 | `5a00fa5c202ad94ba62fdc6559e1d2be92efb8eb` | included | Exact frozen history retained; no manual conflict. |
| #2338 | `0d90807a58a7da4de4838007d0882a53b66f8828` | included | Exact frozen history retained; no manual conflict. |
| #2339 | `fae6d6950634205512c8fc8f9976f4bb38da215b` | included | Exact frozen history retained; no manual conflict. |
| #2340 | `d5b95328c2dc6d951996cbb81c86af166ce00eb5` | included | Exact frozen history retained; no manual conflict. |
| #2341 | `903c8f84cbc45c09dcc29fe48e7ee0fa46db4154` | included | Exact frozen history retained; no manual conflict. |
| #2342 | `c414cd6a327517b75072c3744a092130074d2ddf` | included | Exact frozen history retained; no manual conflict. |
| #2343 | `e5a51a230d5e744f61502e135579c21289b96012` | included | Exact frozen history retained; no manual conflict. |
| #2344 | `e621b8405a94f5f565704dc83bdae34fbc7bb230` | included | Exact frozen history retained; no manual conflict. |
| #2345 | `8ef17e4c2fbd2ed0ad989c3e84171b0d4768c681` | included | Exact frozen history retained; no manual conflict. |
| #2346 | `8aa468b85b277d4e0f34720b89824426fca4b9a8` | included | Exact frozen history retained; no manual conflict. |
| #2347 | `feef04354604662252cd70c3f94f2255b50837aa` | included | Exact frozen history retained; no manual conflict. |
| #2348 | `494663917938dd010fee08be6d717394d6e13b20` | included | Exact frozen history retained; no manual conflict. |
| #2349 | `96ed12239679927f8c7f5eccef4d5e4681fc9a0c` | included | Exact frozen history retained; no manual conflict. |
| #2350 | `b5ba11c5e610a574b81b91a84851e32f451612ac` | included | Exact frozen history retained; no manual conflict. |
| #2351 | `5329a1acb9e3096107e3cddb3a900be7d0d87c26` | included | Exact frozen history retained; no manual conflict. |
| #2352 | `48c60b593e7abdd20441f8461fd2d2de3b584627` | included | Exact frozen history retained; no manual conflict. |
| #2353 | `5f205c45b542f850a0065eb3490e89aab385e2f5` | included | Exact frozen history retained; no manual conflict. |
| #2354 | `b93f0c76334f7724d15113e5bb6a3c0139efa8dc` | included | Exact frozen history retained; no manual conflict. |
| #2355 | `ed9cbf9c9abb859dad3604f010a8c776361086a1` | included | Exact frozen history retained; no manual conflict. |
| #2356 | `c518e31c45fa0e883502ea8d861eea8a3aabfee6` | included | Exact frozen history retained; no manual conflict. |
| #2357 | `ca8cd0b6d2656c2adac28bd8e89b3c3adcf1ad11` | included | Exact frozen history retained; no manual conflict. |
| #2358 | `e274130578c5417b6e3c25784e7ad9fff3606eeb` | included | Exact frozen history retained; no manual conflict. |
| #2359 | `21df54ec9c69af2f027b9f4319439ae65dbcd5ec` | included | Exact frozen history retained; no manual conflict. |
| #2360 | `79d3ec328864d735ae81f596f5e244300ff88570` | included | Exact frozen history retained; no manual conflict. |
| #2361 | `ed2da9977d0e67c8e9eeee0587be7e8a1ccdc48b` | included | Exact frozen history retained; no manual conflict. |
| #2362 | `9560c1ee8607bc32d32b633a76ba4f8498092e25` | included | Exact frozen history retained; no manual conflict. |
| #2363 | `457a123c366bbb9a3d99d7f7c317454205e79bde` | included | Exact frozen history retained; no manual conflict. |
| #2364 | `bd70bc02ed805d6ba4750b8bd57114c839de394c` | included | Exact frozen history retained; no manual conflict. |
| #2365 | `869486120602e019822372882fe278d68380ad49` | included | Exact frozen history retained; no manual conflict. |
| #2366 | `22c7b368cc3952d21fa8f90c35f468229c9ce5a7` | included | Exact frozen history retained; no manual conflict. |
| #2367 | `6a987f6006ef2d94fdaaa76d3b4072ab3f63e045` | included | Exact frozen history retained; no manual conflict. |
| #2368 | `796f97ac8032757c54db5d48120769f4b9143be6` | included | Exact frozen history retained; no manual conflict. |
| #2369 | `ffb75e0cabc7fc72cbd27f659d159e1a7c9a39ab` | included | Retain summary-sidecar exclusion from #2364 and metadata-based meeting classification from #2369; preserve both regression tests as separate methods. |
| #2370 | `8e76882bb4f5d2fd9f34b36428b9457e7de1e482` | included | Exact frozen history retained; no manual conflict. |
| #2371 | `278da976701ceb63e3c40e75a4177802c6d5d13b` | included | Exact frozen history retained; no manual conflict. |
| #2372 | `47ed4f8f1602317fe39ebfdaf75edeb9e964eef2` | included | Exact frozen history retained; no manual conflict. |
| #2373 | `db82f431fba8e3f23deaa4c18c465e6740a3d10d` | included | Exact frozen history retained; no manual conflict. |
| #2374 | `70c47e1c2097491e3f9cb23e2a03c2e1cf8a5105` | included | Exact frozen history retained; no manual conflict. |
| #2375 | `d48b1490c7f6ca4becbeb7a233b5f22cc007be26` | included | Exact frozen history retained; no manual conflict. |
| #2376 | `9c6cae0d622862850618ecf1ce65223e248d45f1` | included | History retained; active wording deferred to proposal. Owner decision pending. |
| #2377 | `b5d86adfbf43ab62ee009d19aaba52fb92d219af` | included | Exact frozen history retained; no manual conflict. |
| #2378 | `c4ed9322ce3ef9ea10a7e71b112a8193947b9836` | included | Exact frozen history retained; no manual conflict. |
| #2379 | `b97c3031bfdadb9ae34f557914e1cc8c8dcc4925` | included | Exact frozen history retained; no manual conflict. |
| #2380 | `73ece1c517a12266502bed0f255599c805c6e57b` | included | Keep both Companion guard suites and the independent Sentry symbol registration suite in PY_TEST_SUITES. |
| #2381 | `76229f7ea11c41b85f898e27ba1e8bbc6dffe21d` | included | Use #2381 current pin-checker inventory guidance and real-window sharing-test description in the three overlapping documentation paragraphs; supersedes #2336 stale hotspot examples. |
| #2382 | `6632fff7d64f19029d31bccbd2cd211138c603a5` | included | Exact frozen history retained; no manual conflict. |
| #2383 | `71e3fd9f902656218f9cb5426153ad1166021736` | included | Describe edge-driven recording receipts from #2383 rather than stale poll-based overlap sampling from #2336; recording-start subscription and both learning paths retained. |
| #2384 | `8b8b7330366140bc09585eb25dac1d8d8a6f2ce2` | included | Exact frozen history retained; no manual conflict. |
| #2385 | `9dae21964e3c92b700ca28b46c5fdb7913a2b4b9` | included | Exact frozen history retained; no manual conflict. |
| #2386 | `c40174cab38aad001e7ac175a1ab90384037a80e` | included | Exact frozen history retained; no manual conflict. |
| #2387 | `9d247c7ed8c738587c253000b47c0f52583c8eb6` | included | Exact frozen history retained; no manual conflict. Owner decision pending. |
| #2388 | `7eeaef0fadc463c99d309f6b41bec6fa3aa634ab` | included | Exact frozen history retained; no manual conflict. |
| #2389 | `9117f727ead0e382ae3aad00272c6666bfdd4087` | included | Exact frozen history retained; no manual conflict. |
| #2390 | `45557e293c3f7848db553761a4e48ff33d2cc98d` | included | #2330 replaces the old 1.1.68-to-1.1.69 harness. Preserve its matching 1.1.75-to-1.1.76 RC procedure and apply #2390 version-specific/non-current-checklist qualification using the actual new pins; do not restore obsolete e42 candidate instructions. |
| #2391 | `7c5572a027e948abf320eec48d82758da88bee57` | included | Exact frozen history retained; no manual conflict. |
| #2392 | `d37cd1bca46dc58232910094d22241b141691394` | included | Exact frozen history retained; no manual conflict. |
| #2393 | `6f3361a14704e8008ca34b0c44f78489e1854d45` | included | Exact frozen history retained; no manual conflict. |
| #2394 | `b7a441f73138b043e7000844b258b8959c72fa37` | included | Exact frozen history retained; no manual conflict. |
| #2395 | `f45657075acc0895632576e8abe12e0e3cfddff4` | included | Exact frozen history retained; no manual conflict. |
| #2396 | `630ea7e869e4ddc18b76b3cf0cf49c7d889bd150` | included | Exact frozen history retained; no manual conflict. |
| #2397 | `3002d9f1325ae389c39f35f45e841e379ceddc7b` | included | Exact frozen history retained; no manual conflict. |
| #2398 | `da8d491b94583ea2f74758915a822796f5684446` | included | Exact frozen history retained; no manual conflict. |
| #2399 | `7078345138ffcb2c3c4c9a9467d49e1134c69c0e` | included | Exact frozen history retained; no manual conflict. |
| #2400 | `b123722e067272f6d2be5301aaff635289b492f1` | included | Exact frozen history retained; no manual conflict. |
| #2401 | `bdca0cbff86cff00520a9037ef113e7b9d876c0f` | included | Exact frozen history retained; no manual conflict. |
| #2402 | `cad31bd515f301aa75ec1268492e8630802e904f` | included | Add NextSentenceClaude.swift to the fast-test source list for the new real transport EOF regression tests; preserve existing line-process lock fix from #2336. |
| #2403 | `cb906745566f6e1fff9fbb7008f33cd98e0687aa` | included | Exact frozen history retained; no manual conflict. |
| #2404 | `1487dca33ab7233d7067afd75eac778e0552ce16` | included | Exact frozen history retained; no manual conflict. |
| #2405 | `0edc793c73c852c820bd8679c5ef6662f29adc34` | included | Exact frozen history retained; no manual conflict. |
| #2406 | `6f2a0e7cefdcb80b1d24531230518f94a177608c` | included | Exact frozen history retained; no manual conflict. |
| #2407 | `a7e715a496ebfb8a844f9e859578e2b5d0251081` | included | Exact frozen history retained; no manual conflict. |
| #2408 | `3cb950e41bc19c10245d26c65e4aaa51b5cba6f0` | included | Retain current correct/verify skills and stop hook inventory from #2336, remove the writing-port agent inventory matching the deleted completed agent definitions in #2408. |
| #2409 | `fc8bdf25b6a3689595c0005255f9ecc8f71ce1ec` | included | Retain separate YAML rules for imported-audio component proof and MCP publishing guards; append MCP guard suite without dropping Companion or Sentry suites. |
| #2410 | `baec57997d0b595a3a778d2cb932d4912c2f5db3` | included | Exact frozen history retained; no manual conflict. |
| #2411 | `355db737f9c2b76c0e7a507854763c4eba483bd7` | included | Keep actual skills plus stop hook inventory and #2408 removal of completed writing agents; #2411 QA skill routing changes merge unchanged. |
| #2412 | `c6684ba5dbd9bc3ccc1ff4891427dd86980d0cb2` | included | Exact frozen history retained; no manual conflict. |
| #2413 | `1629ffa351e3ff0a16c0651b408f30bd16281e7f` | included | Exact frozen history retained; no manual conflict. |
| #2414 | `1de98008a18e81419b504c07a2f5ea1a84be99a8` | included | Prefer #2414 precise RMS/silence comment describing main-dispatched mic updates; discard #2336 obsolete RT-thread commentary only, retaining actual independent silence policies. |
| #2415 | `eb9474f79986b26977b8242b12ab8f82b164c644` | included | Exact frozen history retained; no manual conflict. |
| #2416 | `e6e385753a905fef9e185770c5fb05c2596e59a8` | included | Exact frozen history retained; no manual conflict. |
| #2417 | `f2df44b7bd6efe34199c4eaacc686acd7f1023da` | included | Exact frozen history retained; no manual conflict. |
| #2418 | `70bb585393bf01a87c3223551bdfd3ebad948ace` | included | Keep Live tool inventory from #2336 and Companion non-Swift-package classification from #2418; both directories exist. |
| #2419 | `e26d8a8875e2108e91adc5b2ef87c7337a3db4a7` | included | Exact frozen history retained; no manual conflict. |
| #2420 | `74008d11d497b517e46c5c06ad5ac7dec4e43b87` | included | Exact frozen history retained; no manual conflict. |
| #2421 | `14780af8818f103011ed9b6fea3be356a24a26d8` | included | Exact frozen history retained; no manual conflict. |
| #2422 | `556b25e6dada4841b5ca98e4bbb1a39325ade525` | included | Apply current plural source-pin guidance and concise CallActivity/NextSentence entries from #2422 while retaining #2335 OpenScreenDiagnostics entry. |
| #2423 | `34ebcf25352d105a6faa6563d21ca7b19e4ba81e` | included | Apply #2423 removal of obsolete poll constants and literal equivalent 120-second wait ceiling, superseding #2336 explanatory comment. Updated behavior-based ceiling test retained. |
| #2424 | `4793ed6197955e13274cbf729e499786a010f8da` | included | Exact frozen history retained; no manual conflict. |
| #2425 | `9347af651dd79f85f4c92c93702272bced83c189` | included | Keep three distinct matrix rules and all guard suites; prefer #2425 explicit SDK BLOCKED source gate and wrapper-contract-only proof over #2336 manual SDK description. |
| #2426 | `e9e0a52ab3def8be28dfdbf182ec4de161d4dfa1` | included | Exact frozen history retained; no manual conflict. |
| #2427 | `41d0412e4df1532515b1734ca0a922e5cb62a698` | included | Retain #2336 accurate unused-memory-buffer description while preserving #2427 post-append trimming correction. #2429 later removes the buffer. |
| #2428 | `538762183271931a4c249291683bb7508a7555ea` | included | Exact frozen history retained; no manual conflict. |
| #2429 | `24e9e61fab73dfa5e140ea099b8bcde5eaa8ff2c` | included | Remove obsolete entries/ObservableObject descriptions with #2429 actual buffer removal and retain #2393 ordered writes. Preserve #2427 accurate post-append trim timing in the sink table. |
| #2430 | `70ed121b1815b820303e59b8e57f7778290cb7a7` | included | Retain #2336 operational/lab inventory additions; #2430 corrected nightly digest output destination remains applied above the conflict. |
| #2431 | `018e3746f64bfba9e96aed664df07871acee381d` | included | Exact frozen history retained; no manual conflict. |
| #2432 | `47a53d0660cb000fe65eb82b164f65c5d65627da` | included | Use #2432 precise active-release-asset versus frozen-legacy feed distinction while keeping the legacy feed owner-path classification. |
| #2433 | `840680e760070fdc9dcce9f54448aa867db9c176` | included | Keep Companion non-Swift inventory from #2418 alongside #2433 Live owner-guide addition. |
| #2434 | `d28bc4fbc15b8a4ef3cfb96dedc57aab355e8531` | included | Apply #2434 exact account-separation steps 4–6 within the existing setup guide; same owner-controlled account separation, more precise link text. |
| #2435 | `e70c0a88587ec1e358008ff82a39f744c1db68a3` | included | Use #2435 XCTUnwrap failure in fileSize and owned cleanup helper; remove #2336 obsolete trailing failure/throw that a textual merge incorrectly attached to the new nonthrowing cleanup method. Preserve migration setup failure semantics. |
| #2436 | `be26c0922a087625350f49887b9ef7f12f6482bd` | included | Prefer #2436 complete parsed completion-marker list including canceled and explicit default-open/all semantics over narrower #2336 wording. |
| #2437 | `b969f1e6a40b9901f6c66e59a3cc8d278f08614f` | included | Prefer #2437 current tracked directory descriptions and avoid a dated empty-size-baseline claim; preserve surrounding #2336 inventory additions. |
| #2438 | `1300ee793fcee58d6bea70b81c0d424698e902aa` | included | Use #2438 precise workflow trigger and default-branch checkout facts, distinguishing declared secret references from configured secrets. |
| #2439 | `63da0ac262c63f4ab7e8e3fef0176e80346206d2` | included | Use #2439 qualified heuristic summary descriptions and no-summary-row behavior, avoiding #2336 overclaim that every saved meeting carries summary frontmatter. |
| #2440 | `547cd95924634ffcb28def337c60795d37fc15e6` | included | Exact frozen history retained; no manual conflict. |
| #2441 | `a1da5916df11076bc90cfe31de85b21c76121624` | included | Keep shared path-boundary helper and both original sibling regression and stronger #2441 legacy/current descendant/override controls. Explicitly inject empty environment into original sibling test to preserve test isolation. |
| #2442 | `9ace288fb6591e8b758683ffba91b174477bbc66` | included | Use #2442 precise cwd-relative default path explanation and root invocation; this documents existing behavior only. |
| #2443 | `33c11f5b99ed6ad7414918ec3bfb4e1e4f600938` | included | Exact frozen history retained; no manual conflict. |
| #2444 | `5a9ab4042010632fea825da891e23a5d97be9981` | included | Exact frozen history retained; no manual conflict. |
| #2445 | `be9183681334c2a7288aaafbd06d52903fe02afe` | included | Exact frozen history retained; no manual conflict. |
| #2446 | `2031d980c892f69f1522f453d2ef7d49acabb71c` | included | Use #2446 complete engineering-guide index and qualified procedure/design descriptions; retain #2419 correct six-sink count including Writing. |
| #2447 | `5d0dc3d7e11ca3cea4bd0003d547d139d65413a2` | included | Exact frozen history retained; no manual conflict. |
| #2448 | `bfc3b9bac0a7763804877735335a7d475e061bc2` | included | Exact frozen history retained; no manual conflict. |
| #2449 | `23875ba3c750ad465326b157031a842884f5b576` | included | #2449 and #2336 implement the same pending-before-native-call correction. Keep concise #2449 comment and its stronger regression coverage; no behavior rollback. |
| #2450 | `2fea9c87f2d02c35d5ceacc80b54d61405057c91` | included | Whitespace-only conflict: obsolete isValid validator was already removed by #2336. Preserve extended key display cases and record exact #2450 history. |
| #2451 | `ea7fa1179b6cdf75525a671f413d11537cae6c47` | included | Exact frozen history retained; no manual conflict. |
| #2452 | `497081f2322522a9a4fc51b266f28f0d3b9264d1` | included | Exact frozen history retained; no manual conflict. |
| #2453 | `d6fa851d6a5e11ae261d710af088f9de868aabae` | included | Exact frozen history retained; no manual conflict. |
| #2454 | `c82357428a13ef9fcf993098e83ca093bb1ae6af` | included | Retain #2454 bounded-count-only diagnostic clarification without reintroducing DictationPasteRetryTelemetry removed by #2447. |
| #2455 | `51db4bd0863cf354f623f78cbb96086aa284d6f2` | included | Use #2455 current hook-readability explanation; keep read-only --check and actionable hint, never install hooks or modify shared repository config. |
| #2456 | `25913c7c758f6b7466659e9c4065051e17c177d4` | included | Add new MeetingTranscriptSavedPolicy to the fast source list; do not resurrect DictationPasteRetryTelemetry removed by #2447. Core TranscriptSaveOrigin source merged too. |
| #2457 | `1cc40b9e9ea58c08a9b8dd6d3641bcb51be6cd6c` | included | Exact frozen history retained; no manual conflict. |
| #2458 | `a9fcac9a311581453db85af23f326fca6bd8d621` | included | Exact frozen history retained; no manual conflict. |
| #2459 | `f39a4fa5df48bfc9c263823e6e0006f018dd716f` | included | Exact frozen history retained; no manual conflict. |
| #2460 | `ceec6e9f8a7b978f082fbfc83b724fddb7d97b6f` | included | Exact frozen history retained; no manual conflict. |
| #2461 | `4883724e70734b84a3531fefda7853b48a3aceba` | included | Apply #2461 more complete factual storage inventory (per-embedder databases, retained speaker metadata, exact day/index/model locations). No new retention choice, exclusion, or privacy promise is adopted. |
| #2462 | `06e9915e76bd326c30a7527bd5e823f94c0f6fc7` | included | Exact frozen history retained; no manual conflict. |
| #2463 | `8fea3e535dbfd3d625e705babc22717d940c480f` | included | Use #2463 source-verified AX file/caller inventory, caller-side capping/scrubbing, and actual display/fallback manual scenario; same secure-field boundary. |
| #2464 | `163d50632d856fb4fdad0e8811bfc0e9ceb6c5c3` | included | Exact frozen history retained; no manual conflict. |
| #2465 | `d03471bc12af2ccf3283ae3447793f8e640774d5` | included | Exact frozen history retained; no manual conflict. |
| #2466 | `c46ebf56b9940d6e12c1077131358a026afbee7a` | included | Keep equivalent #2336 scalar-view JSON control escaping (avoids per-scalar temporary strings); incorporate #2466 exhaustive actual-log regression tests. All U+0000–U+001F remain escaped. |
| #2467 | `8ad269e29942a696605660509816c5adfcf0843e` | included | Exact frozen history retained; no manual conflict. |
| #2468 | `ce425fd1530c152cc647b2f6fcd6bfac39d313bd` | included | Prefer #2468 explicit Core file-I/O exception and serialized append contract, and nonexhaustive app-facing type inventory; no module edge or runtime change. |
| #2469 | `4bf2a6b87b316e3fb19cef62d78ae6722da4275b` | included | Use #2469 controller-run ownership wording for external mic selection; Bluetooth opt-in behavior unchanged. |
| #2470 | `1fab45fa9671a520c585bc15eb9fad1c89763bbd` | included | Exact frozen history retained; no manual conflict. |
| #2471 | `76982df38a2868cae9bd5a96964306ea0f16aeb5` | included | Exact frozen history retained; no manual conflict. |
| #2472 | `41fe997fe0146dd52981e4eeff10da53734be658` | included | Exact frozen history retained; no manual conflict. |
| #2473 | `474b8602f19993f641c84166aa293eb327612d0d` | included | Exact frozen history retained; no manual conflict. |
| #2474 | `39ef561d01ba6975dc7370e95d952d0af39a5d4a` | included | Exact frozen history retained; no manual conflict. |
| #2475 | `7fb539218d5159c5d0dd97c810eeb762ca380614` | included | Exact frozen history retained; no manual conflict. |
| #2476 | `d0ecd3d2f52866ac40224beb1349664d623e87e1` | included | Exact frozen history retained; no manual conflict. |
| #2477 | `e4b4129fbb5d0f53ff786c35875c617508e05524` | included | Exact frozen history retained; no manual conflict. |
| #2478 | `64e912e05306e2b604466df35fe452910c86d824` | included | Exact frozen history retained; no manual conflict. |
| #2479 | `38b2706f4e403e9bd12fa96dfcc45e6f05d3a3b5` | included | Exact frozen history retained; no manual conflict. |
| #2480 | `7875118586425ae19763d34963a068476c0d904e` | included | Exact frozen history retained; no manual conflict. |
| #2481 | `2b12f3967533e40e23e84c30ff4eaa5c3c974fd2` | included | Exact frozen history retained; no manual conflict. |
| #2482 | `fa514de342b7633dafcaa68879d314b126203c1a` | included | Exact frozen history retained; no manual conflict. Owner decision pending. |
| #2483 | `28978d947411be2e0d0dbe1d35fa56a2a2cbeba9` | included | Exact frozen history retained; no manual conflict. |
| #2484 | `d02500c0ed7a34ec540c8705085b979bbd503072` | included | Adopt #2484 async generation/cancellation-aware prepared input-source provider and trusted selection. Omit writes to keyboardEnableResult/keyboardSelectSucceeded removed as unread state by #2336; retain all guards and actual enable/select outcomes. |
| #2485 | `a4b90b42e3c641126c0def2bb6be6187668f02f7` | included | Compose #2485 background prompt delivery/deadline-before-write with #2402 EOF/send-failure semantics and injectable timeout scheduler. Preserve onSendFailure callback before helper reports failure, with NextSentenceOnce selecting exactly one completion. Restore callback box required by injected scheduler tests. |
| #2486 | `49fb48c7018f7a3c7400d47a35130fb86fc2ef1b` | included | Exact frozen history retained; no manual conflict. |
| #2487 | `2bb9a480a213b2fa320a6b8a8e5b5dbce220b0b1` | included | Exact frozen history retained; no manual conflict. |
| #2488 | `50bd6362e9d08cb405823325d317b5752c069d18` | included | Exact frozen history retained; no manual conflict. |
| #2489 | `20ea6237bbe74a23dfa734655fc98cf4fadde465` | included | Exact frozen history retained; no manual conflict. |
| #2490 | `eb382b08a833f95bde429102051bc616736bdb2a` | included | Remove obsolete retained-combo-box inventory matching #2490 deletion; preserve actual NSTextField-based speaker autocomplete surface and guidance. |
| #2491 | `8f36f0a64ec996eb411d2cbcf4715ee84fe351a9` | included | Exact frozen history retained; no manual conflict. Owner decision pending. |
| #2492 | `2aca9ea405618988f6e429585f043ad5c4cfb7e4` | included | Exact frozen history retained; no manual conflict. |
| #2493 | `acaf3814d2a4e39741a705e1a230e665b7415d65` | included | Exact frozen history retained; no manual conflict. |
| #2494 | `b60e8ceb1cab5f06dd89cf82f4785934d195e71a` | included | Exact frozen history retained; no manual conflict. |
| #2495 | `cfe23e26cc69895022362ab3caf0cc8a5ddb0a57` | included | Exact frozen history retained; no manual conflict. |
| #2496 | `21cd293abc84f5e851917368ca5c8e9c759c47d8` | included | Exact frozen history retained; no manual conflict. |
| #2497 | `9c9b37109548fba1f54f15c181d225aba02c1127` | included | Exact frozen history retained; no manual conflict. |
| #2498 | `cbdc067eb3b660d721589e898238e919b67ac16f` | included | Exact frozen history retained; no manual conflict. |
| #2499 | `2fb32b5d1f4dbc73a7a114c19c4e85d8542074f2` | included | Exact frozen history retained; no manual conflict. Owner decision pending. |
| #2500 | `ebf64cfc89ee6ad5489b7baad94b1720986d2196` | included | Exact frozen history retained; no manual conflict. Owner decision pending. |
| #2501 | `b5dce85bea53a6599390fbb535688b6ae51fc815` | included | Exact frozen history retained; no manual conflict. |
| #2502 | `71136206f7e8b238f842ba3485cf279dc0ad19e8` | included | Keep #2502 asynchronous archive completion waits and producer joins on success/failure; use current SpeakerNamingRequest signature without recognizedPeopleCount removed by #2336 (and subsequently #2515). |
| #2503 | `ab1cda0fc57a6a548516a0c95c64cd5a4a520ef8` | included | Exact frozen history retained; no manual conflict. Owner decision pending. |
| #2504 | `d3b9061e699e51e4775ca4bba17dcebb8f99d1cf` | included | Exact frozen history retained; no manual conflict. |
| #2505 | `875d2dc9fa35166238bc078d9b2f5db3a148c0fa` | included | Exact frozen history retained; no manual conflict. |
| #2506 | `69f46bf1dea75e4ac663a50ac29386cfe4f1b94e` | included | Exact frozen history retained; no manual conflict. |
| #2507 | `73c5a77e5efbb7dc4bfba066aad8fc6c54cd7129` | included | Remove both obsolete methods: #2507 replaces padSystemAudioGapBeforeNextBuffer with token-owned observation/gap admission; #2492 already removed unused finalizeMicRecoveryArtifacts. Preserve registered mic recovery and all new observation ownership helpers. |
| #2508 | `3bc4ca16d52566f9db2c7757f45337e4011765a5` | included | Exact frozen history retained; no manual conflict. Owner decision pending. |
| #2509 | `087e643ae8d68778aebab19ac3da718e0b733ef3` | included | Exact frozen history retained; no manual conflict. |
| #2510 | `4fcf9d0f924e4d936f0a2383fccd89e4e6ffb8c5` | included | Exact frozen history retained; no manual conflict. |
| #2511 | `c5ef08302aeef31b910704a31b7bb59fe0ae4ee9` | included | Exact frozen history retained; no manual conflict. |
| #2512 | `828880748f25c21c7096ff6fb24620778ee127de` | included | Exact frozen history retained; no manual conflict. |
| #2513 | `fb8c70b56be0af5d30306914d011586a3363b6d5` | included | Exact frozen history retained; no manual conflict. |
| #2514 | `60277a632ced11b4a74b5fd526e2118ca21cb516` | included | Exact frozen history retained; no manual conflict. |
| #2515 | `550d127fec4f98b73c6771022df8f9bec948d505` | included | Keep current count-free SpeakerNamingRequest call and #2502 asynchronous archive waits/producer cleanup. #2515 removed count is already absent via #2336; retain focused tests/doc changes. |
| #2516 | `3c3a08d69d0647b02582d5084ac4d621763e97b5` | included | Keep #2516 accurate separate dismiss/remindSoon routes after unused snooze wrapper removal; required Remind later product flow remains intact. |
| #2517 | `6ccd5592b5b00b4005c23944563201f03e869f5b` | included | Exact frozen history retained; no manual conflict. |
| #2518 | `f2572900105bd0883013cad69d432e92129a4944` | included | Exact frozen history retained; no manual conflict. Owner decision pending. |
| #2519 | `a9cbbed19719c0035313638e0a75a315743a531f` | included | Exact frozen history retained; no manual conflict. Owner decision pending. |
| #2520 | `8e460a132c58552bd976648125db9041e4e275aa` | included | Exact frozen history retained; no manual conflict. |
| #2521 | `cf650719ff2c2e658bc29171b76952f582090fc4` | included | Exact frozen history retained; no manual conflict. Owner decision pending. |
| #2522 | `4e513cf917c8e79713ff268e772ba1a2c9f2da59` | included | Exact frozen history retained; no manual conflict. |
| #2523 | `f977e74bf78d0599ce7d903b93f231b74989207e` | included | Exact frozen history retained; no manual conflict. |
| #2524 | `047b4438c9fc90b58a3bd2d8e91623914ac61510` | included | Exact frozen history retained; no manual conflict. |
| #2525 | `ff7827fd4e71d1cbbca5b5aa18a8bb9cd9eddd79` | included | Exact frozen history retained; no manual conflict. Owner decision pending. |
| #2526 | `7eb193e7334c8819adc691c0d4e0120aa9aab184` | included | Exact frozen history retained; no manual conflict. Owner decision pending. |
| #2527 | `ee8beb8d1335bdd65d68b6502fec5a3cc28d0b48` | included | #2527 and #2336 already require host-owned Audio injection. Keep focused host wording and existing NSWorkspace notification-center injection; no fallback Audio construction is restored. |
| #2528 | `bb9b0f29e1138db1de2404f79f8c171ca2d467b4` | included | Exact frozen history retained; no manual conflict. |
| #2529 | `1cd0ad996b62a3eab0032881793aa421a5b22af7` | included | Exact frozen history retained; no manual conflict. |

## Authorized expansion — 2026-11-11 UTC

Starting integration head: `0f558e7fc3577e0bd1ba8b545a4dc6fb69d8dbbf`.
All additional bases are main, with no stacked base-branch dependencies.
Saved-audio status/timings (#2539/#2547) and saved-person presentation
(#2554/#2556) are semantic combinations, not ancestry-only proof.
Three conflicts were resolved: hidden-transcript clock wording with existing
private immutable clock retained; metric-only speaker merge diagnostics replacing
UUID fields; and confirmation-progress comment wording with behavior retained.
No blanket file strategy was used. Prior full-gate and scroll-smoke fixes remain.

New decision worksheets remain unselected. The recent-lineup worksheet describes
main: the earlier broad #2336 candidate already removes its public convenience
value, while retaining the model-specific factory. That retirement/compatibility
choice remains pending owner review; importing #2555 does not approve it.

| PR | Frozen head | Disposition | Actual behavior / reconciliation |
| --- | --- | --- | --- |
| #2531 | `f3d3f7a131e76d53100eaf1197c36823fa7d3e0c` | reconciled | Whisper publications carry their concrete variant owner; both router query and emitted-state paths use the same projection. |
| #2532 | `0e8d3f1e74f01c06f14c92313a1bbaf444642bd1` | history retained; proposal unselected | Unselected backend role worksheet only; no backend deletion or permission choice. |
| #2533 | `9f0196f779e7da8d470fd53befeaa835fe44243e` | history retained; behavior already present | Unused promptsObserver declaration and shutdown cleanup already absent through #2336; exact history retained without reintroducing them. |
| #2534 | `8b0430f332b98d89224b1f32841e0780699b7689` | history retained; proposal unselected | Unselected automatic speaker-merge worksheet only; no thresholds or identity mutation policy chosen. |
| #2535 | `93378cb67e94eb6e04f8ab959a9c4ff1656525f3` | history retained; behavior already present | File-drop/JSON-or-argv transport wording already corrected through #2336; exact history retained. |
| #2536 | `567280c50fc77eea9f3547be731e75146c19c12d` | history retained; proposal unselected | Unselected companion-access worksheet only; no tool grants, defaults, consent or listing changes. |
| #2537 | `1f8d1db8f725f634e1b90ecf94c4921bcf068b86` | reconciled | Remove unused monitor stop facade; keep registrar stop/generation cleanup and consumer unsubscribe behavior. |
| #2538 | `6ed7e7f37e93af078cf13f34c40d512a2e982606` | history retained; behavior already present | Static glow wording already present through #2336; no visual behavior changes. |
| #2539 | `b207ce087bfd58deecc165c6455b1b5603981dbf` | existing runtime reset retained; regression fixture added | Four-second rejected-input status reset already present through #2336; add actual manager publisher regression fixture. |
| #2540 | `53b3882daa448a12f0370e7dc230189c88a7cb78` | history retained; proposal unselected | Unselected main-branch protection worksheet only; no remote branch or merge policy changes. |
| #2541 | `f0b246ea5aab20182dc643cbb087dd05557bfe05` | reconciled | Unknown selected input ID zero discards the pending analytics report before cache/identity refresh; known categorical transitions retain debounce behavior. |
| #2542 | `c633ddeb6aa6a4783e34e7857bc367c8835f5919` | history retained; proposal unselected | Unselected changelog worksheet only; no release flow or version policy chosen. |
| #2543 | `267b34f0629c2adb47a8470eb5d39275bdb65d49` | reconciled | Use accurate flush-policy test comment while retaining existing private immutable clock; do not reintroduce mutable injection seam. |
| #2544 | `6eac465675ed3d3a6c0495388ec65c1fb74a12fb` | reconciled | Stop displayed review clips on off-screen transition and explicitly mark the retained view off-screen before releasing sheet ownership. |
| #2545 | `b55508504e2717b70e50b2218be0c311c8d4b2de` | history retained; behavior already present | Final dictation placeholder already hidden through #2336; exact history retained. |
| #2546 | `f7621a22c828d116c711c445fdf7974a911cf2d4` | history retained; proposal unselected | Unselected monthly mutation worksheet only; no workflow, runner admission or schedule changes. |
| #2547 | `4004cc38d86746e14ba4d93d6b0978caef6354c1` | reconciled | Saved-audio pipeline holds process activity and binds a job-local timing recorder; successful save publishes its snapshot. Preserve replacement lease and cancellation ordering. |
| #2548 | `9b4caac3119bb7d44fc5f71507ca08f819a555d4` | reconciled | Stable first-seen tie ordering for capped RRF candidate union; correct recall claims and add pure limit tests. Ranking-policy worksheet remains unselected. |
| #2549 | `c6804dc713667e80d462ab116eb9f531140d5310` | history retained; proposal unselected | Unselected display-placement worksheet only; no AX, latency or placement contract changes. |
| #2550 | `3b7570894835fddd589726bc41fc99e4348c6758` | reconciled | Aggregate matched speaker rows by capture filename, preserving matched totals and representative name/quote; exclude every matched alias from profile co-speakers. |
| #2551 | `ec34d38492c969819d23ceb0ace78b72f5ae3f07` | history retained; proposal unselected | Unselected Personal History retention worksheet only; no deletion, consent, preference or learning policy changes. |
| #2552 | `fad2489ca2fe6722a5e1824051055e2c3bb48517` | reconciled | Remove UUID identity fields retained by broad #2336 diagnostics; use metric-only explicit/duplicate metadata helpers and preserve merge transactions. |
| #2553 | `911c23de3abb4c203c070885ab65475d8da5e0c6` | history retained; proposal unselected | Unselected Writing model-copy worksheet only; no model picker, runtime or public API choices adopted. |
| #2554 | `ef6a30194d5518008765b89b6dca1df63ac79b19` | reconciled | Clarify saved-person comment and ring progress wording; existing afterYes behavior remains unchanged. |
| #2555 | `d98c97c73fc0517418e0ed369e9f5e9d906dbb5e` | history retained; proposal unselected | Unselected recent-lineup public API worksheet only. Existing #2336 candidate removes the convenience value, while the model-specific factory remains; compatibility/retirement remains an explicit unresolved owner decision, not approved by this worksheet. |
| #2556 | `1896bcbf85a31b174c9f6eeabae0be62fde5821f` | reconciled | Thread optional meeting-specific confirmation requirement from pipeline identity options through SpeakerNameChoice into saved-person review progress; nil retains standard fallback. |
| #2557 | `a1bd1203362f3583da009754c980a3cf64313914` | history retained; behavior already present | Capture comments already anonymized through #2336; exact history retained with no runtime audio changes. |

### Expansion proof limits

The additional exact heads were fetched through one batch of namespaced Git PR
refs and compared with the frozen manifest before merging. All 225 ancestry
checks pass, and all original 198 ledger entries and the original frozen-input
hash compare byte-for-byte as JSON values with the starting ledger.

On the expanded runtime tree, a network-denied pure component passed 168/168
assertions across the actual Whisper projection, route-reporting debounce, and
speaker-progress fixtures. It compiles the actual model-choice declarations
without invoking preference methods and extracts only the actual two pure route
value/state declarations from their larger source file. No engine/router/native
object is constructed. The actual MCP value models/fusion with its committed
standalone fixture passed 11/11 assertions under network denial. A separate
actual merge-metadata/sanitizer component passed 13/13 assertions; this is a
plain-value fixture, not the Core XCTest runner. Three standalone XCTest runner
setup attempts failed before execution (missing XCTest module, missing Swift
assertion overlay, then unavailable XCTMain/testCase); their raw compiler logs
are preserved locally. These setup failures are not rewritten as passing tests.

All 1,042 app-source Swift files pass syntax parsing. This does not typecheck or
link the app. Source lists, module boundaries, documentation paths, source pins
(17 resolved pins), and diff whitespace checks pass. The verifier selection
lists meetings, UI, speed and real-mic/AirPods work, with MCP integration outside
its coverage. Selection is not execution or app proof. No owner-profile native
verifier, full unfiltered suite, app build/launch, model, clipboard or hardware
check was executed for this expansion. Saved-audio manager XCTest and actual MCP
index/profile runtime tests remain pending on the trusted isolated pathway.

The earlier 0f558e7 normal Swift CI run 42900322086 was still QUEUED at the one
GraphQL observation during expansion. Its three accessible associated completed
runs (42900321825, 42900321953, 42900322171) reported SUCCESS. The old literal
full-bench run 42900362954 outcome was not refreshed through rate-limited REST.
None of these older-source outcomes is proof of this expanded tree.

The expansion `bash check.sh quick` completed PASS: 111 passed, 0 failed,
0 skipped (268 seconds). This ran against the expanded runtime merge head
`89f0b3f03` while the provenance documentation was being extended; no scripts or
runtime sources changed during it. Final documentation-path and whitespace
checks pass after the documentation edits. The earlier failed 198-head checks
remain historical failures; this is a separate expanded-tree result. Full gate
CI-parity contract tests included in this run pass. The parent still must review
the added diff, and exact pushed-head hosted compilation/full bench and native
acceptance remain pending.
