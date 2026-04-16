# Neutralize Playdate — Documentation

## Fonts

### Title Logo ("NEUTRALIZE" on title screen)
- **Font:** `fonts/Rubik-ExtraBold-64`
- **Stroke width:** `strokeW = 4` (circular white outline)
- This combination produces the correct large, thick, rounded logo with a tight white stroke.
- Do not substitute `Rubik-Bold-48` (too small, wrong weight) or `Rubik-Medium-64` (file does not exist in assets).
- **Warning:** Running `pdc source/ Neutralize.pdx` produces a broken build where the title overflows the screen, even with identical source. Always restore the PDX from the known-good commit `ce08ab8` if a rebuild is needed, or test the title screen immediately after any rebuild.
