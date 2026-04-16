# Neutralize Playdate — Feature Backlog

## ✅ Completed

### Core Gameplay
- [x] **Persistent Saving** — `playdate.datastore` saves board state, score, and high score
- [x] **Title Screen** — Home screen layout optimized for 400×240 landscape
- [x] **Hero Tile Animation** — Decorative dithered tile with subtle bounce (size 50px, 1px stroke)
- [x] **Game Board & Moves** — Full game logic ported to Playdate Lua

### UI & Visuals
- [x] **Thematic 1-Bit Aesthetic** — Dithering, chunky fonts, monochrome 1-bit design
- [x] **Juicy Home Animations** — Snappy D-Pad slide animations, responsive feedback
- [x] **Metadata & Branding** — `pdxinfo`, `card.png` (launcher banner), `icon.png`, splash screen
- [x] **Stats Display** — Drawer overlay showing lifetime stats (high score, games played, neutralizations, merges)

### Audio
- [x] **Sound Effects** — Click/clack for swiping, chime for neutralizing, grind for crank board dumps
- [x] **System Menu Integration** — Audio mute toggle via `playdate.menu`
- [ ] **8-Bit SFX & Music** — Convert to authentic 8-bit style using Playdate synths
- [x] **Crank SFX** — Ratchet tick on shuffle charge, game-over restart, pause drawer; Shepard tone on celebration

### Achievements
- [x] **Achievement System** — 18 unlockable achievements with progression
- [x] **Achievement Descriptions** — Display requirement text below each achievement name
- [x] **Achievement Icons** — Animated sparkle (✨) for unlocked; hollow diamond (◇) for locked
- [x] **Progress Bars** — Show `current / target` for mastery achievements (one-off achievements show description only, no bar)
- [x] **Visual Polish** — Centered icons in rows, twinkling sparkles per achievement, clear row separation
- [x] **Startup Catch-Up** — On app launch, check if player has earned any achievements since last save and backfill them

### Stats Tracking (Behind the Scenes)
- [x] **Efficiency Tracking** — `score / time` — Rewards speed + accuracy (points per second)
- [x] **Tidiness Tracking** — `score / moveCounter` — Rewards strategic, efficient play (tracked but not exposed at launch)
- [x] **Level 4 Completion Time** — Track fastest completion time for level 4
- [x] **High Score Persistence** — Best single-round score tracking

### Drawer UI
- [x] **Drawer Pull-Tab** — Visual indicator at minimum height
- [x] **Scrollbar** — Visible when content exceeds drawer height (with guard against negative height)
- [x] **Drawer Idle Peek Animation** — Auto-peeks upward periodically from rest position (228px) to show content, then bounces back

---

## 🔄 In Progress / Pending

- **Drawer Idle Peek Animation** — Fine-tuning timing and animation curve for the auto-peek behavior

---

## 📋 Backlog (Deferred)

### Challenges & Progression
- [ ] **Challenges** — Limited-time puzzle objectives with rewards (e.g., "Neutralize 20 tiles without shuffling", "Clear the board in under 2 minutes")
  - Optional: tier structure (Easy → Hard)
  - Optional: reward cosmetics or bonus points
- [ ] **Daily Challenges** — One rotating challenge per day, resets at midnight, tracks streak
  - Optional: leaderboard for daily high scores
  - Optional: daily login bonus

### Leaderboards
- [x] **Efficiency** — Highest `score / time` ratio (fastest high-scoring runs)
- [x] **Highest Score** — Best single-round scores
- [x] **Local Leaderboard Wrapper** — `Scoreboards.lua` handles local JSON storage, designed to swap for Panic API later
- [x] **Initials Entry** — Players enter 3-char initials after each game; last used initials pre-filled
- [x] **Leaderboard Display** — Top 5 per board shown at bottom of Progress Report drawer (name, date, score)
- [x] **Catalog Leaderboards** — Catalog API wired (`isCatalog` flag, `prefetch` cache, fixed `(status, result)` callbacks); swap `BOARD_IDS` strings in `Scoreboards.lua` once Panic allocates them

### Drawer System
- [ ] **Top + Bottom Drawers** — Top drawer for quick settings/controls, bottom drawer remains Progress Report. Both retract independently; game board is pushed/shrunk between them when both are open.

### Future Enhancements
- [ ] **Haptic Feedback** — Vibration on shuffle, merge, and game-over events (if Playdate SDK supports it)
- [ ] **Mini-Board in Pause Menu** — Editable screenshot or board state display (itch.io sharing)
- [ ] **Crank Board Dump Visual Polish** — Enhanced animation and dust/particle effects
- [ ] **Theme System** — Multiple 1-bit palettes (e.g., "Classic", "Inverted", "Monokai")
- [ ] **Easter Eggs** — Hidden unlock conditions, secret animations, or bonus achievements

---

*Last updated: 2026-03-30*
