# Neutralize Playdate — Documentation

## Fonts

### Title Logo ("NEUTRALIZE" on title screen)
- **Font:** `fonts/Rubik-Bold-48`
- **Stroke width:** `strokeW = 5` (circular white outline, derived from `math.floor(3 * (60/36))`)
- This combination was copied from `Neutralize_Web/Playdate_Port/source/main.lua` — the original Playdate port source of truth.

### MYSTERY SOLVED — the "broken rebuild" wasn't pdc's fault
For several hours we believed `pdc source/ Neutralize.pdx` produced a broken title rendering despite identical source code. That was wrong.

**What actually happened:** the committed `ce08ab8` PDX was compiled from `Neutralize_Web/Playdate_Port/source/main.lua` (font: `Rubik-Bold-48`, `strokeW = 5`). But `source/main.lua` **in this repo** had been edited to use `Rubik-ExtraBold-64` + `strokeW = 4` — which renders ~437 px wide, wider than the 400 px Playdate screen. So the source file did not match the PDX that shipped. Every rebuild was faithfully compiling what the source said, not what the committed PDX represented. **pdc is deterministic — trust the rebuild.** If a rebuild looks wrong, the source has drifted from the committed bundle.

**How we found it:** `diff Neutralize_Web/Playdate_Port/source/main.lua <(git show ce08ab8:source/main.lua)` — the authoritative source shows different font and strokeW values.

### Title rendering approach (from Neutralize_Web)
- Image sized to the text, not the screen: `gfx.image.new(tw + buf*2, th + buf*2)`
- Text drawn left-aligned at `(buf, buf)` using `gfx.drawText` (NOT `drawTextAligned(center)`)
- Image drawn centered on screen: `splashTitleImage:draw(200 - imgW/2, titleY - buf)`
- Defensive sizing (forcing a 400 px-wide image) causes mid-glyph clipping when text is wider than the image — don't do it.
