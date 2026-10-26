// lint-fixture-path: Sources/UI/FixtureLoginRow.swift
// Naming the SMAppService.Status type calls nothing.
import ServiceManagement
struct LoginRowModel {
    var status: SMAppService.Status
    var isOn: Bool { status == .enabled }
}
