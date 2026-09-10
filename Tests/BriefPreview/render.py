#!/usr/bin/env python3
"""Render the actual brief view in an isolated, never-shown macOS hosting window."""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [Path(__file__).with_name('RenderBrief.swift'),
           ROOT / 'boringNotch/Interaction/BriefPromptRow.swift',
           ROOT / 'boringNotch/Interaction/Core/BriefPresentation.swift',
           ROOT / 'boringNotch/components/Live activities/MarqueeTextView.swift']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/validation/brief/layout-compact')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
    with tempfile.TemporaryDirectory(prefix='notchisland-brief-preview-') as scratch:
        contents = Path(scratch) / 'BriefPreview.app/Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'BriefPreview', 'CFBundleIdentifier': 'dev.validation.brief-layout',
            'CFBundleName': 'Brief Layout Preview', 'CFBundlePackageType': 'APPL', 'LSUIElement': True,
        }))
        executable = contents / 'MacOS/BriefPreview'
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                        '-module-cache-path', str(Path(scratch) / 'ModuleCache'),
                        *map(str, SOURCES), '-o', str(executable)], cwd=ROOT, check=True)
        subprocess.run([str(executable), str(output)], cwd=ROOT, check=True)
    for name, digest in hashes.items():
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest:
            raise RuntimeError('Source changed during rendering: ' + name)
    (output / 'manifest.json').write_text(json.dumps({
        'generatedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'evidenceType': 'Actual macOS NSHostingView cacheDisplay from an isolated, never-shown window',
        'sources': hashes, 'nativeAppInteractionVerified': False,
        'readsProductionPreferencesOrNotifications': False,
        'reduceMotionEvidence': 'Explicit preview override in the actual view; no system accessibility setting was changed or verified',
        'legacyEvidence': 'Reconstructed former ContentView music-row geometry using the current legacy MarqueeText source; not a historical screenshot',
        'geometryEvidence': 'Actual row uses compiled BriefPresentationLayout.rowHeight; legacy reconstruction retains its historical 40-point height. Exact dimensions are in render-summary.json.',
        'limitations': 'Static initial marquee layout only; no claim about native hover, click routing, long-running scroll or notification delivery.',
    }, indent=2) + '\n')


if __name__ == '__main__':
    main()
