# Lunchbox Toolkit — Forever

An all-in-one levelling companion for **World of Warcraft: Forever** (`## Interface: 16001`).

Your gear and your quest rewards, judged against **weights you can see and change** — not a
black box, and not a tier list. Everything the addon decides can be read in one line and
overruled in one click.

> **Release candidate.** The code is complete and gated offline; the first real sessions are
> happening at launch. Anything that disagrees with the client is fixed in place and noted in
> the release notes. Nothing in this README is claimed as "tested in game" unless it says so.

---

## Install

1. Close the game.
2. Extract the release zip into `Interface\AddOns` so that
   `Interface\AddOns\LunchboxToolkit\LunchboxToolkit.toc` exists. The zip root holds
   the six addon folders; extract the **folders**, not a wrapper folder.
3. Start the game and enable all six folders.

Five of the six are plugins (Racials, Rogue, Threat, Vendor, WeaponBuffs). They declare
`Dependencies: LunchboxToolkit` and stay dormant unless the core is present. Each one is
optional; disabling a plugin only removes its feature.

## First run

The first time a character logs in with the addon, a short tour opens: what the addon does,
tooltips, quest rewards, bags, the switches, a suggested levelling direction, and the ranks
board. Nothing is written until you press Finish; closing early changes nothing, and
**/lt setup** reopens it whenever you want.

Nothing else is on by default that can move, sell or spend anything.

---

## What it does

### Item tooltips — the core

Hover any wearable item and the panel gives it a score and a verdict for each of your builds:
*upgrade*, *downgrade*, or *not for this build*. The score is your profile's weights applied to
the item's real stats, with caps counted. The same number appears in the bags, on the
character sheet, and on quest rewards, so one item never gets two answers.

Weights are per class, role and spec, and every one is visible and editable in **Profiles →
Weights**. Bundled values are marked *provisional*; measured values are marked *measured*.

### Quest rewards — the picker

Reward icons get a border: **purple** for the biggest upgrade, **blue** for the second,
**green** for something you can use later (a Warrior's plate at 40), **gold** for the reward
worth most to a vendor. If nothing beats what you wear, the addon says so instead of colouring
everything.

### Talents — the ability picker and the route

* **/lbs** — the talents you can take right now, ranked by what they are worth to your build,
  each with the reason and the score.
* **/lbs next** — the next step of an authored levelling route ("level 24: Ancestral
  Knowledge 1/5 — opens the Stormstrike tier").
* **/lbs route** — the whole path from your level.

The scorer and the route are shown side by side. When they disagree, both are printed and the
route is named as the route; nothing is silently overruled. At 1.0.0 the Enhancement Shaman
1–60 route is authored (plus the "Water Shield First" variant).

### Caps — targets you can see

Hit, expertise, spell hit and the tank defence target, per level band, with the rating
equivalent when the client can supply it. A cap whose value cannot be measured says
**"not measured yet"** rather than inventing a number and quietly tilting your score.

### Ranks — the levelling board

Guild and party boards of levelling pace: active time, level, deaths, fastest to 60.
Sharing is **opt-in**, off by default, one packet a minute on a level-up, and it refuses to
send inside an instance. **/lt ranks export** gives you the table as text to paste anywhere.

It is a guild/party board by design, not a server ladder: addon messages only reach people you
are grouped with, and there is no shared store.

### Gear check and bags

* **/lt scan** — what in the bags beats what you wear, split into *now* and *soon*, with the
  level that unlocks a "soon" item.
* A bag item that wins gets an arrow; a **Keep: best in slot at 40** line appears on the item
  that will win once wearable.
* One button in the bag header: **Sort** normally, **Sell junk** at a merchant (first press
  borders, second press sells exactly those).
* One line at a merchant: free bag slots, repair cost, junk value.

### Sorting, if you liked BankStack

`/lt sort mode order` switches from the client's sort to the same ordering BankStack produces:
quality first, then class order (weapon, armour, consumable, trade goods …), armour and weapons by
equip slot, smaller stacks first, pet cages and empty slots last. `/lt sort preview` prints the plan
without moving anything, `/lt sort bags|bank|all` applies it (the bank must be open), and
`/lt sort reverse` flips it. Implemented independently — BankStack is all-rights-reserved, so its
code is not used. Off until you turn it on; normal bags only.

### Vendor

Grey selling, score-based junk selling and auto-repair are **all off by default and all
per character**. Auto-repair spends your own money only — never guild funds. Nothing is ever
destroyed, moved or equipped.

### Shaman

Totem timers with per-totem durations (Magma 20 s, Mana Tide 12 s, …), hidden until you know
your first totem, plus an optional 5-second mana cast clock and a Totemic Recall cue. The
clock never prints a mana number in combat, because power is a secret value on this client.

---

## Your own numbers

The shipped weights are one opinion; yours are another. Copy a base profile (**Profiles →
copy**) and edit it in **Weights** — that is where a preference like "spell crit and haste over
melee crit, Strength above everything" lives. Custom profiles are saved per account; nothing
you change there affects the shipped data or a template.

---

## Commands

| Command | What it does |
|---|---|
| `/lt` | the main window |
| `/lt setup` | the tour / build wizard |
| `/lt scan` | gear check |
| `/lt lbs [next\|route]` | talent ranking, next route step, whole route |
| `/lt ranks [export]` | the board, or a copyable table |
| `/lt vendor` (`/lbv`) | vendor status, junk sale, repair |
| `/lt sort [bags\|bank\|all]` | sort — the client's sort, or the BankStack-style order (`mode order`), with `preview` and `reverse` |
| `/lt drop list` | bag triage / ignore list |
| `/lt diag chat on\|off` | diagnostic lines in chat |
| `/lt debug` | session debug output |
| `/lt test` | the internal self-test (debugging aid, not an in-game test) |

## Compatibility

* **Bagnon / Baganator** — bag *replacements*. They own the bag frames, so the upgrade arrow,
  the bag-open check and the header button stop appearing. Set **Settings → Window → Bag
  frames → replacement add-on** and the addon says so instead of going quiet. Do not install a
  bag replacement until the bag features are confirmed, or accept that trade.
* **Auctionator** — no overlap. Safe.
* **Questie / Questdon** — no overlap with the tooltip or the gear scoring. Questdon also
  marks the "best" quest reward; if you want one signal only, switch one of the two off.
* **Leatrix Plus** — turn **"Hide addon menu"** off (Minimap page). It hides the client's addon
  compartment, which is this addon's normal launcher. Leatrix's *Sell junk* and *Repair
  automatically* also overlap with the Vendor plugin — use one of the two.
* **BankStack** — sorts bags and bank. This addon's `/lt sort` calls the client's own sort, so
  use one; there is no clash unless both are run at the same moment.

## Known unknowns

The game was offline while this build was written. These are verified by code and offline
harnesses only, and are the first things to watch in play: talent ranking on a live client,
the totem slot order on Forever, the vendor price read, the bag frame it annotates, and
whether the first-use tour opens where it should.

`/lt diag chat on` and `/lbp capture on` (dev build) record what actually happened.

## Licence

MIT — see `LICENSE`. Fork it, change it, argue with the weights; the licence asks only that
the copyright notice travels with the copies you pass on.

The addon icon beside it (`Media\Inv_treasurechest_felfirecitadel_64`) is Blizzard
Entertainment's artwork, shipped unmodified for identification. It is not covered by the MIT
licence. World of Warcraft and Blizzard Entertainment are trademarks or registered trademarks
of Blizzard Entertainment, Inc. This add-on is not affiliated with or endorsed by Blizzard.
