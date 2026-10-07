# Emuktan interface design

Status: proposal for approval. Values live in `lib/ui/theme/app_tokens.dart`; this file explains the intent. A clickable mockup accompanies it.

## 1. Direction

Calm, clear and quick to operate at a busy counter. The look follows the Apple Human Interface Guidelines, adapted to a Windows 11 desktop app: one system typeface, generous space, a single accent colour, content before chrome, and state shown by form as well as colour.

HIG principles, applied here:

| HIG principle | What it means in Emuktan |
|---|---|
| Clarity | One job per screen. Amounts and stock are the largest things on the Sell screen. Nothing under 12 px. |
| Deference | The interface stays quiet. White content on a faint grey window, thin separators, no heavy borders or shadows. Colour is kept for meaning. |
| Depth | Only sheets (dialogs) float above the page. Everything else sits flat. |
| Consistency | The same button, field, chip and table look the same everywhere. New screens use existing tokens, never new values. |
| Direct manipulation | Click a medicine to add it. Step quantities in place. Edit in place, avoid separate edit screens. |
| Feedback | Every action gets a visible result: a toast, a state change, or a sheet. Nothing fails silently. |
| User control | Confirm only what is destructive or hard to undo. Everything else can be undone or edited. |

## 2. Platform adaptation

- **Typeface:** Segoe UI Variable (Windows 11), falling back to Segoe UI. Fonts are never downloaded because the app must work offline. Figures use tabular alignment so columns of money line up.
- **Window:** standard Windows title bar and controls. Sidebar navigation on the left (the HIG "source list"), content on the right, status bar at the bottom.
- **Input:** designed for mouse, keyboard and barcode scanner first. Touch-friendly sizes are used where speed matters (see 5).
- **Appearance:** light by default (bright counter), dark follows the Windows setting.

## 3. Information architecture

Sidebar, shown according to who is signed in:

| Item | Cashier | Nurse / clinician | Owner |
|---|---|---|---|
| Sell | yes | yes | yes |
| Patients | register, search | full records | full records |
| Stock | view, receive | view, receive | everything |
| Time clock | own | own | everyone |
| Reports | no | no | yes |
| Staff and settings | no | no | yes |

Signing in: choose your name, then enter a PIN. The app locks after inactivity and on "Switch user".

## 4. Layout

- 4 pt spacing grid: 4, 8, 12, 16, 24, 32, 48.
- Window padding 24. Panels on `surface`, window on `window`. Panel radius 12, control radius 8, sheet radius 16.
- Sidebar 208 px. Sell screen: working area plus a fixed 340 px summary panel on the right.
- Minimum window 1024 x 640. Designed for a 1366 x 768 laptop and scales up.
- Status bar always shows: backup/sync state, offline state, signed-in user.

## 5. Sizes and type

| Role | Size | Weight | Use |
|---|---|---|---|
| Amount | 32 | 700 | Sale total, change due |
| Large title | 28 | 700 | Sign-in, empty states |
| Title | 20 | 600 | Screen titles |
| Headline | 15 | 600 | Panel headings, row names |
| Body | 14 | 400 | Default |
| Callout | 13 | 400 | Secondary information |
| Caption | 12 | 500 | Labels, chips, status bar |

Targets: 40 px standard, 48 px on the Sell screen (Charge, quantity steppers, PIN keys, payment choice).

## 6. Colour

One accent (clinical blue). Status colours are separate from the accent and always carry an icon or word, never colour alone.

| Role | Light | Dark |
|---|---|---|
| Window | #F4F6F8 | #14171B |
| Surface | #FFFFFF | #1D2127 |
| Sidebar | #EBEEF2 | #191C21 |
| Text / secondary / tertiary | #14181F / #586171 / #687180 | #F1F3F6 / #A9B1BE / #8F98A6 |
| Accent | #0A64AD | #59AEF0 |
| Success | #18733E | #4CC27E |
| Warning | #9A5B00 | #E8A33B |
| Critical | #C62B27 | #FF6B63 |

Every text pair is tested to WCAG AA (4.5:1) in `test/theme_test.dart`.

## 7. Components

- **Button:** filled accent for the one main action per screen; outlined for the rest; text for low-emphasis. Destructive actions use critical red, and are never the default.
- **Segmented control:** for 2 to 4 mutually exclusive choices (Cash / M-Pesa, Pack / Strip / Tablet).
- **Field:** label above, value inside, help or error below in words.
- **Chip:** small status label with icon and text (In stock, Low stock, Expires Dec 2026, Expired).
- **Banner:** inline notice inside a panel. Used for patient allergies.
- **Sheet:** the only floating element. Title, one sentence of explanation, two buttons: the safe one on the left, the action on the right.
- **Toast:** short confirmation, bottom of the window, disappears on its own.
- **Table:** 44 px rows, no zebra stripes, header in caption style, numbers right-aligned.

## 8. Behaviour rules

1. **Scanner and keyboard:** the search field takes focus when Sell opens. A scan (barcode, then Enter) adds the item. `Ctrl+K` jumps to search from anywhere on Sell. `Esc` closes a sheet.
2. **Selling units:** each medicine shows only the ways it is actually sold (pack, strip, single). The row says what leaves stock, for example "2 strips = 20 tablets".
3. **Batches:** the system picks the batch that expires first and shows it. Staff never choose a batch by hand during a sale.
4. **Discounts** need a clinician's approval. A cashier sees a sheet asking a clinician to enter their PIN. The approver is recorded on the sale.
5. **Charge button** says exactly what will happen ("Charge KES 1,320"). If it is disabled, a line under it says why.
6. **Warnings in plain words:** "Expired. Do not sell." beats "Status: 3".
7. **Offline is normal.** No error dialogs for a lost connection. The status bar says "Working offline" and sales continue. A sync that has not succeeded for 24 hours turns the status bar amber and says so.
8. **Empty states** say what will appear and how to add the first item.
9. **Destructive actions** (void sale, write off stock) use a sheet that states the consequence, and ask for a reason.
10. **Never block on the owner.** If a clinician is away, a discount simply cannot be applied; the sale can still be completed at full price.

## 9. Writing

- Plain English, short sentences, active voice. Buttons are verbs: "Charge", "Receive stock", "Save note".
- Money: `KES 1,320` (cents shown only when non-zero, and always on receipts: `KES 1,320.00`).
- Dates: `07 Oct 2026`. Time: 24 hour, `14:32`. Expiry: `Dec 2026`.
- Quantities include the unit: "842 tablets", never "842".
- Errors say what happened and what to do: "That PIN is not right. Try again, or ask the owner to reset it."

## 10. Accessibility

- Text contrast at least 4.5:1, tested.
- Status never relies on colour alone.
- Visible focus ring on every control (2 px accent). Full keyboard path through every screen.
- Respect the Windows "reduce animation" setting. Motion is 120 to 200 ms and only confirms a change.

## 11. Open questions

1. Will the counter PC have a touchscreen? (Decides whether 48 px targets are needed beyond Sell.)
2. Screen size and resolution of the PC to be bought.
3. English only, or English and Swahili labels?
4. Logo and brand colour: the clinical blue is a proposal, not taken from an existing brand.
5. Can the owner approve discounts when no clinician is present? (The scope says clinician only; the owner also works the counter.)
6. Receipt layout and paper width (58 mm or 80 mm) once the printer is chosen.
