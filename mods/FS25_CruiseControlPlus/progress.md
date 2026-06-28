# Cruise Control Plus – Progress

| Phase | Status | Notes |
|-------|--------|--------|
| 1. Mod skeleton | Done | modDesc, register, Settings (defaults), CruiseControlPlus, CruiseControlPlusVehicle, l10n, progress.md |
| 2. Input hook | Done | CruiseControlPlusHook.lua wraps Drivable cruise handler (actionEventToggleCruiseControl or scan). |
| 3. Double-tap detection | Done | lastToggleTime + windowMs; double-tap consumes, single passes to original. |
| 4. Speed extraction & conversion | Done | getCurrentSpeedKmh(vehicle, config): getLastSpeed, round, clamp, nil if below min. |
| 5. Cruise target set & activate | Done | setCruiseTargetToCurrentSpeed; cruiseControlMaxSpeed, cruiseControlActive/State. |
| 6. Config system | Done | loadFromXML/saveToXML for doubleTapWindowMs, roundingStepKmh, minKmh, maxKmh, showHudNotification. |
| 7. Edge cases | Done | Reverse: skip set when speed &lt; 0. Low speed: nil + optional blinking warning. No cruise: check spec fields. Gamepad: action-based. |
| 8. Optional HUD notification | Done | "Cruise set to X km/h" for 2 s when showHudNotification on; draw() in mod instance. |
| 9. BUGFIX speed-unit | Done (2026-06-28) | "4" fell back to 1 km/h above ~36 km/h. Cause: getCurrentSpeedKmh preferred `vehicle.lastSpeed` (which is m/ms, not m/s) and multiplied by 3.6 -> ~0 -> clamped to 1. Fix: trust `getLastSpeed()` (returns km/h, authoritative; verified vs GDN factor 3600), fall back to `lastSpeed * 3600` only if method missing. Below-min now returns nil (warning) instead of clamping to 1. |
