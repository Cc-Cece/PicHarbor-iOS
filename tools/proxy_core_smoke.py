"""Exercise the pinned Apple binary with synthetic nodes, outside the iOS app host.

No subscription credentials, real servers or user configuration are used.
"""
from pathlib import Path
import json
import os
import subprocess
import shutil
import zipfile
from prepare_proxy import prepare

ROOT = Path(__file__).resolve().parents[1]

def run():
    prepare()
    output = ROOT / 'build/proxy-core-smoke'
    output.mkdir(parents=True, exist_ok=True)
    prefix = 'Clash.xcframework/macos-arm64_x86_64/'
    with zipfile.ZipFile(ROOT / '.runtime-cache/clash3-Clash.xcframework.zip') as archive:
        for item in archive.infolist():
            if not item.filename.startswith(prefix) or item.is_dir():
                continue
            target = output / item.filename[len(prefix):]
            target.parent.mkdir(parents=True, exist_ok=True)
            if ((item.external_attr >> 16) & 0o170000) == 0o120000:
                if not target.is_symlink():
                    os.symlink(archive.read(item).decode(), target)
            else:
                target.write_bytes(archive.read(item))
    basic = dict(name='test-node', server='127.0.0.1', port=9)
    variants = [('socks5', dict(type='socks5')),
                ('anytls-minimal', dict(type='anytls', password='synthetic-password', sni='example.invalid')),
                ('anytls-fingerprint', dict(type='anytls', password='synthetic-password', sni='example.invalid', **{'client-fingerprint': 'chrome'})),
                ('anytls-full', dict(type='anytls', password='synthetic-password', sni='example.invalid', alpn=['h2', 'http/1.1'], udp=True, **{'client-fingerprint': 'chrome', 'skip-cert-verify': False}))]
    cases = []
    for name, fields in variants:
        node = dict(basic, **fields)
        configuration = {'mode': 'rule', 'log-level': 'silent', 'allow-lan': False,
                         'bind-address': '127.0.0.1', 'port': 0, 'socks-port': 0, 'mixed-port': 0,
                         'external-controller': '', 'external-controller-unix': '',
                         'tun': {'enable': False}, 'dns': {'enable': False},
                         'profile': {'store-selected': False, 'store-fake-ip': False},
                         'proxies': [node], 'listeners': [dict(name='picharbor-0', type='mixed', listen='127.0.0.1', port=24500, proxy='test-node')],
                         'rules': ['MATCH,REJECT']}
        cases.append(dict(name=name, configuration=configuration))
    fixtures = output / 'fixtures.json'
    fixtures.write_text(json.dumps(cases))
    executable = output / 'smoke'
    subprocess.run(['clang', '-fobjc-arc', '-fmodules', '-ObjC', '-I', str(ROOT / 'Sources/Bridge'),
                    '-F', str(output), '-framework', 'Clash', '-framework', 'Foundation', '-framework', 'Network',
                    '-framework', 'Security', '-framework', 'SystemConfiguration', '-framework', 'CoreFoundation', '-lresolv',
                    str(ROOT / 'Sources/Bridge/ProxyCoreBridge.m'), str(ROOT / 'tools/proxy_core_smoke.m'), '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(fixtures)], check=True)
    # Test the actual Swift proxy model without bootstrapping the Python iOS app
    # host. Only localization/error display is stubbed; routing/storage logic is copied verbatim.
    package = output / 'package'
    for folder in ['Bridge/include', 'Sources', 'Tests']:
        (package / folder).mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / 'Sources/Bridge/ProxyCoreBridge.h', package / 'Bridge/include')
    shutil.copy(ROOT / 'Sources/Bridge/ProxyCoreBridge.m', package / 'Bridge')
    for name in ['ProxyRouting.swift', 'ProxyProfiles.swift', 'SubscriptionQRCode.swift', 'ProxySelection.swift', 'BackupModels.swift', 'BackupStore.swift', 'QueueScaling.swift', 'TaskPresentation.swift']:
        text = (ROOT / 'Sources/Core' / name).read_text()
        (package / 'Sources' / name).write_text('import ProxyBridgeHarness\nimport Combine\n' + text)
    for name in ['ProxyProfileTests.swift', 'ProxyCompatibilityTests.swift', 'SubscriptionQRCodeTests.swift', 'ProxySelectionTests.swift', 'QueueScalingTests.swift', 'ActivityOrderingTests.swift']:
        (package / 'Tests' / name).write_text('import ProxyBridgeHarness\n' + (ROOT / 'Tests' / name).read_text())
    (package / 'Sources/Support.swift').write_text('''import Foundation
struct HarborError: LocalizedError {
    let code: String; let detail: String?
    init(_ code: String, detail: String? = nil) { self.code = code; self.detail = detail }
    var errorDescription: String? { detail ?? code }
}
enum L10n {
    static func text(_ key: String, _ values: [String] = []) -> String {
        var result = key
        for (i, value) in values.enumerated() { result = result.replacingOccurrences(of: "{\\(i)}", with: value) }
        return result
    }
}
''')
    framework_path = json.dumps(str(output))
    (package / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PicHarbor", platforms: [.macOS(.v14)], targets: [
    .target(name: "ProxyBridgeHarness", path: "Bridge", publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc", "-F", FRAMEWORK])],
            linkerSettings: [.unsafeFlags(["-F", FRAMEWORK, "-framework", "Clash", "-framework", "Foundation", "-framework", "Network", "-framework", "Security", "-framework", "SystemConfiguration", "-lresolv", "-Xlinker", "-ObjC"])]),
    .target(name: "PicHarbor", dependencies: ["ProxyBridgeHarness"], path: "Sources"),
    .testTarget(name: "ProxyTests", dependencies: ["PicHarbor", "ProxyBridgeHarness"], path: "Tests")
])
'''.replace('FRAMEWORK', framework_path))
    subprocess.run(['swift', 'test', '--package-path', str(package)], check=True)

if __name__ == '__main__':
    run()
