"""Check the OS screenshot from metal_view_demo.dart (requires Pillow)."""
import json
import sys
from PIL import Image

image = Image.open(sys.argv[1]).convert("RGB")
pixels = image.load()


def spans(y, colors):
    runs = []
    for x in range(image.width):
        if pixels[x, y] in colors:
            # Flutter may blend the one-pixel boundary between the colors.
            if runs and x <= runs[-1][1] + 1:
                runs[-1][1] = x + 1
            else:
                runs.append([x, x + 1])
    return [run for run in runs if run[1] - run[0] >= 128]


plain_top = None
for y in range(image.height):
    runs = spans(y, {(255, 0, 0), (0, 255, 0)})
    if len(runs) == 2 and runs[0][1] - runs[0][0] == runs[1][1] - runs[1][0]:
        plain_top = y
        left, reference = runs[0][0], runs[1][0]
        side = runs[0][1] - left
        break
assert plain_top is not None, "Screenshot must contain both reference columns"
composed_top = next(
    y for y in range(plain_top + side, image.height - side + 1)
    if pixels[left, y] == pixels[reference, y] == (255, 235, 59)
)

result = {"image_size": image.size, "side": side, "comparisons": {}}
for name, top in [("plain", plain_top), ("composed", composed_top)]:
    differences = []
    for y in range(side):
        for x in range(side):
            actual = pixels[left + x, top + y]
            expected = pixels[reference + x, top + y]
            differences.append(max(abs(a - b) for a, b in zip(actual, expected)))
    differences.sort()
    mismatch = sum(value > 2 for value in differences) / len(differences)
    # Native triangle rasterization and Flutter's antialiased edges differ.
    # Permit edge variation, but not a missing clip, color conversion or transform.
    assert mismatch < .01, f"{name}: {mismatch:.2%} of pixels differ by more than 2"
    samples = []
    for x, y in [(.25, .25), (.75, .25), (.25, .75), (.75, .75), (.5, .5)]:
        dx, dy = round(x * side), round(y * side)
        actual, expected = pixels[left + dx, top + dy], pixels[reference + dx, top + dy]
        assert max(abs(a - b) for a, b in zip(actual, expected)) <= 1, (name, actual, expected)
        samples.append(actual)
    if name == "plain":
        assert samples == [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255), (128, 128, 128)], samples
    result["comparisons"][name] = {"top": top, "p99_channel_error": differences[int(len(differences) * .99)],
                                    "fraction_over_2": mismatch, "samples": samples}
print(json.dumps(result, indent=2))
