#!/usr/bin/env python3
"""Measure rendered row bounds and text centers; requires Pillow."""
from pathlib import Path
import argparse
import json
from PIL import Image


def text_bounds(path, start_x):
    with Image.open(path) as image:
        rgb = image.convert('RGB')
        points = [(x, y) for y in range(rgb.height)
                  for x in range(start_x, rgb.width - 12)
                  if max(rgb.getpixel((x, y))) >= 40]
        if not points:
            raise AssertionError('No visible text in ' + str(path))
        top, bottom = min(p[1] for p in points), max(p[1] for p in points)
        return {'topPixel': top, 'bottomPixel': bottom,
                'centerPoints': (top + bottom + 1) / 2, 'visiblePixels': len(points)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path,
                        default=Path(__file__).resolve().parents[2] / 'build/validation/brief/layout-compact')
    output = parser.parse_args().output.resolve()
    summary = json.loads((output / 'render-summary.json').read_text())
    row_height = summary['actualRowHeightPoints']
    legacy_height = summary['legacyRowHeightPoints']
    assert row_height == 28, ('Expected current compact row height', row_height)
    assert legacy_height == 40, ('Legacy reconstruction height changed', legacy_height)
    assert len(summary['actualSourceFixtures']) == 32
    actual = []
    for fixture in summary['actualSourceFixtures']:
        name, width = fixture['name'], int(fixture['widthPoints'])
        assert fixture['heightPoints'] == row_height, fixture
        for scale in [1, 2]:
            with Image.open(output / f'{name}-{scale}x.png') as image:
                assert image.size == (width * scale, row_height * scale), (name, image.size)
        measured = text_bounds(output / (name + '-1x.png'), 43)
        assert abs(measured['centerPoints'] - row_height / 2) <= 3, (name, measured)
        assert measured['topPixel'] > 0 and measured['bottomPixel'] < row_height - 1, (name, measured)
        actual.append({'name': name, 'rowCenterPoints': row_height / 2, **measured})
    comparisons = []
    for width in [257, 578]:
        for language in ['zh', 'en']:
            for scale in [1, 2]:
                with Image.open(output / f'legacy-reconstructed-music-{language}-w{width}-{scale}x.png') as image:
                    assert image.size == (width * scale, legacy_height * scale), (width, language, image.size)
            before = text_bounds(output / f'legacy-reconstructed-music-{language}-w{width}-1x.png', 43)
            after = text_bounds(output / f'music-{language}-w{width}-normal-1x.png', 43)
            comparisons.append({'width': width, 'language': language,
                'before': before, 'after': after,
                'afterRowHeightPoints': row_height, 'beforeRowHeightPoints': legacy_height,
                'afterCenterDeltaFromRowCenterPoints': after['centerPoints'] - row_height / 2,
                'beforeCenterDeltaFromRowCenterPoints': before['centerPoints'] - legacy_height / 2})
    result = {'actualRowCount': len(actual), 'allRowsHaveExpectedDimensions': True,
              'actualRowHeightPoints': row_height, 'actualRowCenterPoints': row_height / 2,
              'legacyRowHeightPoints': legacy_height, 'allTextHasVerticalMargin': True,
              'allTextCentersWithin3PointsOfRowCenter': True,
              'actualRows': actual, 'legacyComparisons': comparisons,
              'limits': 'Pixel layout measurements, not native click/hover or long-running animation verification.'}
    (output / 'layout-audit.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k:result[k] for k in ['actualRowCount',
        'allRowsHaveExpectedDimensions','allTextCentersWithin3PointsOfRowCenter','legacyComparisons']},indent=2))


if __name__ == '__main__':
    main()
