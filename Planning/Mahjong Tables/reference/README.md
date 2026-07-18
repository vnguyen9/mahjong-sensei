# Reference images — NOT detector fixtures

Kept for layout/UI reference only. None of these can serve as auto-zoner fixtures:

- `mahjong-2.webp` — real home game (Chinese set), but shot standing, no discards yet.
  Geometry reference for the "walls + empty pond" early state.
- `images-5.jpeg` — real Chinese game mid-play, right content but ~600px thumbnail
  (tiles too small for the 640px detector input).
- `images-2.jpeg` — staged studio scene (walls + pond + a revealed row), tiny resolution.
- `hq720-2.jpg` — **American mah-jongg** (racks, Joker tiles, NMJL scorecard). Faces not in
  the detector's 43 classes; racks hide tiles from the camera.
- `images-3.jpeg` — American mah-jongg again (racks + jokers), thumbnail resolution.
- `images-1.jpeg` — mid-shuffle table, not a game state.

Real fixtures live in `../fixtures/` — see `../SHOOTING-GUIDE.md` for what to shoot.
