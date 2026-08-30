# A roadmap gate that prescribes the diagnostic METHOD can prescribe one that cannot work

- date: 2026-08-30
- surfaced-by: orchestrator
- run: /begin S1b - camera height and the contour flicker
- target: notes           # roadmap-authoring; possibly begin.md

**Evidence.** S1b had to separate two candidate causes of a shader artifact, and its gate named
the experiment as well as the question: "Shoot the valley floor from two distances - (a) changes
with the grazing angle, (b) does not." The Doer shot both poses and they **could not
discriminate**: each saturated at the bottom band, luma 250, `hue_frac.grey` 0.62,
`hue_frac.orange` ~0.0003, because a near-horizontal view maximises the shader's rim term across
the whole ground and swamps the contour contribution the test was trying to read. The prescribed
discriminator was unusable for a reason the roadmap author could not have known without shooting
it.

The Doer did not stop, and did not quietly report the saturated shots as evidence either. It
substituted two measurements the gate had not named - sampling `1 - |n.y|` off the live chunks
(valley floor 0.0000-0.0036 against hillsides 0.0140-0.2295), and arithmetic showing a minor
line emits luminance ~1.20 against a 0.85 glow threshold **everywhere in the frame**, which rules
out (b) on its own premise rather than by observation. The Reviewer then reproduced the normal
sampling independently. The diagnosis is sound; the prescribed method contributed nothing.

**What it suggests.** Roadmap gates should prescribe the **question and the standard of
evidence**, and offer a method as a suggestion rather than as the gate. S1b's gate got this right
in one half and wrong in the other: "the flicker's cause is identified by measurement before it
is fixed, and named in the report" is a standard and survived contact; "shoot it from two
distances" is a recipe and did not. The risk is not that an agent gets stuck - this one did not -
but that a more literal one reports the saturated shots as the discrimination and picks a cause
on evidence that separates nothing, which would pass every test. Worth a line wherever roadmap
sections are authored, and possibly in `begin.md` where it tells the orchestrator to hand the
gate over verbatim: hand it over verbatim, and say that a prescribed *method* inside it may be
substituted with a better one, stated in the report - while the gate's *standard* may not.
