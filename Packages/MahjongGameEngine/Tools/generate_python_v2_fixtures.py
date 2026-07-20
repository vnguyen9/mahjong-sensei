#!/usr/bin/env python3
"""Generate supplied-wall parity fixtures from the authoritative Python sim v2.

Run from the repository root:

  PYTHONPATH="Modeling/mjss/Decision Making/mahjong_ai/src" \
    python3 Packages/MahjongGameEngine/Tools/generate_python_v2_fixtures.py

The generator only reads the nested Python engine. Its output is checked into
the Swift package so package tests never require Python.
"""

from __future__ import annotations

import json
import random
from pathlib import Path

from hkmahjong.sim.v2 import new_game

ROOT = Path(__file__).resolve().parents[3]
OUT = (
    ROOT
    / "Packages"
    / "MahjongGameEngine"
    / "Tests"
    / "MahjongGameEngineTests"
    / "Fixtures"
    / "python_v2_supplied_wall.json"
)


def event_dict(event) -> dict:
    return {
        "kind": event.kind.value,
        "seat": event.seat,
        "tile_type": event.tile_type,
        "instance_id": event.instance_id,
        "draw_kind": event.draw_kind.value if event.draw_kind else None,
        "data": list(event.data),
    }


def player_dict(state, seat: int) -> dict:
    player = state.players[seat]
    return {
        "seat_wind": player.seat,
        "concealed": list(player.concealed),
        "flowers": list(player.flowers),
    }


def observation_dict(state, seat: int) -> dict:
    obs = state.observation(seat)
    return {
        "concealed": obs["concealed"],
        "flowers": obs["flowers"],
        "opp_flowers": obs["opp_flowers"],
        "own_discards": obs["own_discards"],
        "opp_discards": obs["opp_discards"],
        "physical_public": obs["physical_public"],
        "remaining_belief": obs["remaining_belief"],
        "seat_wind": obs["seat_wind"],
        "prevailing_wind": obs["prevailing_wind"],
        "dealer_rel": obs["dealer_rel"],
        "dealer_abs": obs["dealer_abs"],
        "wall_remaining": obs["wall_remaining"],
        "turn": obs["turn"],
        "phase": obs["phase"],
        "last_draw": obs["last_draw"],
        "last_draw_kind": obs["last_draw_kind"],
        "offer_tile": obs["offer_tile"],
        "offer_from_rel": obs["offer_from_rel"],
        "offer_from_abs": obs["offer_from_abs"],
        "legal_actions": obs["legal_actions"],
        "is_terminal": obs["is_terminal"],
    }


def case(case_id: str, wall: list[int], seed: int, dealer: int, prevailing: int) -> dict:
    state = new_game(
        seed=seed,
        supplied_wall=wall,
        dealer=dealer,
        prevailing_wind=prevailing,
    )
    actor = state.current_actor()
    return {
        "id": case_id,
        "seed": seed,
        "supplied_wall": wall,
        "dealer": dealer,
        "prevailing_wind": prevailing,
        "current_actor": actor,
        "wall_front": state.wall_front,
        "wall_rear": state.wall_rear,
        "wall_remaining": state.wall_remaining(),
        "phase": state.phase.name,
        "last_draw": state.last_draw,
        "last_draw_instance": state.last_draw_instance,
        "last_draw_kind": state.last_draw_kind.value if state.last_draw_kind else None,
        "players": [player_dict(state, seat) for seat in range(4)],
        "events": [event_dict(event) for event in state.events],
        "observations": [observation_dict(state, seat) for seat in range(4)],
    }


def main() -> None:
    shuffled = list(range(144))
    random.Random(20260720).shuffle(shuffled)
    corpus = {
        "format": "mahjong-sensei-python-v2-supplied-wall-1",
        "source": "hkmahjong.sim.v2",
        "rules_profile_id": "hk_3faan_v2",
        "rules_hash": new_game(seed=0).profile.rules_hash,
        "cases": [
            case("identity-east", list(range(144)), 0, 0, 0),
            case("reverse-south", list(reversed(range(144))), 17, 1, 2),
            case("shuffled-west", shuffled, 20260720, 2, 3),
        ],
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        json.dumps(corpus, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(OUT)


if __name__ == "__main__":
    main()
