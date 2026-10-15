#!/usr/bin/env python3
"""Checks on the settings form: its parameter spec, its enable rules and the
remembered settings.

The form itself needs JavaFX, which a headless container does not have, so the
rule that decides what is live and the preference round-trip are written as
plain functions in the script and exercised here through the real Groovy
interpreter. What is left - that the spec and the form agree - is lexical.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "qupath" / "ScratchAssayAnalyzer.groovy"
text = SCRIPT.read_text(encoding="utf-8")

sys.path.insert(0, str(ROOT / "benchmark"))
import run_reference_pipeline as rp  # noqa: E402

# ---------------------------------------------------------------- spec checks

spec_block = text[text.index("List paramSpec() {"):]
spec_block = spec_block[:spec_block.index("\n}")]
keys = re.findall(r"\[key:'(\w+)'", spec_block)

assert len(keys) == len(set(keys)), "paramSpec has duplicate keys"
assert len(keys) >= 20, f"only {len(keys)} parameters found"

# Every parameter needs a label and a tooltip, and a tooltip that only restates
# the label teaches nothing - so require it to say appreciably more.
entries = re.findall(r"\[key:'(\w+)', kind:'(\w+)'.*?label:'((?:\\.|[^'])*)',\s*\n\s*tip:'((?:\\.|[^'])*)'\]",
                     spec_block, re.S)
assert len(entries) == len(keys), f"parsed {len(entries)} full entries for {len(keys)} keys"
labels = [e[2] for e in entries]
assert len(labels) == len(set(labels)), "two parameters share a label"
for key, kind, label, tip in entries:
    assert kind in ("text", "check", "choice", "classifier"), (key, kind)
    assert label.strip(), key
    assert len(tip) > len(label) + 40, f"{key}: tooltip barely says more than its label"
    assert tip.strip().endswith("."), f"{key}: tooltip should read as prose"

# The spec is the only place a parameter is described, so every key in it must
# actually reach the config the pipeline reads, and vice versa.
cfg_block = text[text.index("Map c=[selection:selection,"):]
cfg_block = cfg_block[:cfg_block.index("\n        if (c.analysisPercent")]
cfg_keys = set(re.findall(r"(\w+):", cfg_block)) 
for key in keys:
    assert key in cfg_keys, f"{key} is offered by the form but never read"

# Tooltips go on both halves of the row: whichever the pointer lands on.
assert "p.node.tooltip = helpTip(p.tip)" in text
assert "p.labelNode.tooltip = helpTip(p.tip)" in text
assert "t.wrapText = true" in text, "a long tooltip must wrap"

# An inactive row is dimmed and still explains itself. The label must NOT be
# disabled: a disabled JavaFX node receives no mouse events, so disabling it
# would swallow the tooltip exactly when someone wants to know why the row went
# dead. Dimming keeps it hoverable.
assert "p.node.disable = !live" in text
assert "p.labelNode.opacity = live ? 1.0d : 0.45d" in text
assert "labelNode.disable" not in text
assert "reasons[key]" in text
# addListener is overloaded, so a bare closure binds the wrong interface.
assert text.count("} as ChangeListener)") == 3
assert "import javafx.beans.value.ChangeListener" in text
# A disabled field cannot be edited, so it must not be able to block a run.
assert "f[k].node.disable ? defaults[k] : f[k].node.text" in text
# Defaults are captured before the stored values land on top of them.
assert text.index("Map defaults = spec.collectEntries") < text.index("String saved = storeGet(store")
# A typo must not become what the next run starts from.
assert text.index("if (c.inputMode == 'Pixel classifier' && !c.woundClass)") < \
       text.index("storePut(store, 'param.' + p.key, v)")
# Every way of reaching the preference store is guarded: not remembering
# settings is never a reason to fail an analysis.
for guarded in ("java.util.prefs.Preferences settingsStore()", "String storeGet(store, String key)",
                "void storePut(store, String key, String value)"):
    assert guarded in text
assert text.count("catch (Exception ignored) { return null }") >= 2
assert "if (value == null || value.length() >= 8192) return" in text
# There has to be a way back from the remembered settings.
assert "Reset to defaults" in text

print(f"paramSpec checks passed ({len(keys)} parameters, all with tooltips)")

# --------------------------------------------------------- behavioural checks

HELPERS = ["paramSpec", "deadParams", "inactiveReason", "settingsStore", "storeGet",
           "storePut", "isHorizontal"]

PROGRAM = r"""
int failures = 0
def check = { String what, Object got, Object want ->
    if (got != want) { failures++; println "FAIL ${what}: got ${got} want ${want}" }
}
Set all = paramSpec().collect{ it.key } as Set

// Variance mode: the two classifier rows are the only dead ones.
check('variance, everything on',
      deadParams('Variance threshold', true, false, true, 2.5d),
      ['classifierName','woundClass'] as Set)

// Second pass off takes the five refinement rows with it.
check('variance, second pass off',
      deadParams('Variance threshold', false, false, true, 2.5d),
      ['classifierName','woundClass','refineBand','refineVarianceRadius','refineSmoothSigma',
       'refineCloseIterations','refineOpenIterations'] as Set)

// Profiles off takes the stride with it, since stride thins that file alone.
check('variance, profiles off',
      deadParams('Variance threshold', true, false, false, 2.5d),
      ['classifierName','woundClass','profileStride'] as Set)

// Classifier mode with the presence test on still needs the texture map, so
// nothing is dead: the test reads varianceRadius and smoothSigma.
check('classifier, presence test on',
      deadParams('Pixel classifier', true, false, true, 2.5d), [] as Set)

// Classifier mode with the presence test off needs no texture map at all. The
// second pass does not revive it - that builds its own from the refine radii.
check('classifier, presence test off',
      deadParams('Pixel classifier', true, false, true, 0d),
      ['varianceRadius','smoothSigma'] as Set)

// The debug dump of the texture map revives it.
check('classifier, presence off but debug on',
      deadParams('Pixel classifier', true, true, true, 0d), [] as Set)

// Everything off at once.
check('classifier, all optional work off',
      deadParams('Pixel classifier', false, false, false, 0d),
      ['varianceRadius','smoothSigma','refineBand','refineVarianceRadius','refineSmoothSigma',
       'refineCloseIterations','refineOpenIterations','profileStride'] as Set)

// A negative ratio is not a way to leave the test on by the back door.
check('negative ratio counts as off',
      deadParams('Pixel classifier', true, false, true, -1d),
      ['varianceRadius','smoothSigma'] as Set)

// Whatever the inputs, the rule may only name parameters that exist, and may
// never kill the controls the rule itself keys off.
List modes = ['Variance threshold','Pixel classifier']
for (String mode : modes)
  for (boolean sp : [true,false])
    for (boolean dbg : [true,false])
      for (boolean prof : [true,false])
        for (double r : [-1d, 0d, 0.5d, 2.5d, 1e9d]) {
            Set dead = deadParams(mode, sp, dbg, prof, r)
            if (!all.containsAll(dead)) { failures++; println "FAIL unknown key in ${dead}" }
            ['inputMode','secondPass','saveDebug','saveProfiles','minTextureRatio',
             'downsample','analysisPercent','minArea','fillHoles','saveMasks','saveQC'].each {
                if (dead.contains(it)) { failures++; println "FAIL ${it} greyed out by ${mode}/${sp}/${dbg}/${prof}/${r}" }
            }
        }

// Every parameter the rule can switch off has to say what switches it back on.
Map reasons = inactiveReason()
for (String mode : modes)
  for (boolean sp : [true,false])
    for (boolean dbg : [true,false])
      for (boolean prof : [true,false])
        for (double r : [-1d, 0d, 2.5d])
            deadParams(mode, sp, dbg, prof, r).each {
                if (!reasons.containsKey(it) || !reasons[it]) {
                    failures++; println "FAIL no inactive reason for ${it}"
                }
            }
// And must not claim a reason for a parameter that cannot go inactive, which
// would be a reason nobody ever sees.
Set canDie = [] as Set
for (String mode : modes)
  for (boolean sp : [true,false])
    for (boolean dbg : [true,false])
      for (boolean prof : [true,false])
        for (double r : [-1d, 0d, 2.5d])
            canDie.addAll(deadParams(mode, sp, dbg, prof, r))
check('no unreachable reasons', reasons.keySet() - canDie, [] as Set)

// Defaults the README documents.
Map defaults = paramSpec().collectEntries { [(it.key): it.value] }
check('default downsample', defaults.downsample, '4')
check('default analysis field', defaults.analysisPercent, '90')
check('default variance radius', defaults.varianceRadius, '5')
check('default refine band', defaults.refineBand, '20')
check('default min texture ratio', defaults.minTextureRatio, '2.5')
check('default stride', defaults.profileStride, '1')
check('debug off by default', defaults.saveDebug, 'false')
check('fill holes on by default', defaults.fillHoles, 'true')
check('second pass on by default', defaults.secondPass, 'true')
check('mode default', defaults.inputMode, 'Variance threshold')

// Preference round-trip, against the real java.util.prefs store under a node
// of its own so a test run cannot disturb remembered settings.
def store = java.util.prefs.Preferences.userRoot().node('qupath/scratchassay-selftest')
store.clear()
check('absent key reads null', storeGet(store, 'nope'), null)
storePut(store, 'k', 'hello')
check('round trip', storeGet(store, 'k'), 'hello')
storePut(store, 'k2', null)
check('null is not stored', storeGet(store, 'k2'), null)
// Too long to store is dropped rather than thrown: the limit is 8192.
storePut(store, 'big', 'x' * 9000)
check('oversized is dropped', storeGet(store, 'big'), null)
storePut(store, 'edge', 'x' * 8191)
check('just inside the limit is kept', storeGet(store, 'edge')?.length(), 8191)
// A missing store must be survivable, since a locked-down JRE can refuse one.
check('null store reads null', storeGet(null, 'k'), null)
storePut(null, 'k', 'v')
store.removeNode()

// Orientation is remembered by name, so the vertical/horizontal labels have to
// keep agreeing with isHorizontal.
check('vertical label', isHorizontal('Vertical scratch (width measured left-right)'), false)
check('horizontal label', isHorizontal('Horizontal scratch (width measured top-bottom)'), true)
check('unknown name is vertical', isHorizontal(null), false)

println failures == 0 ? "dialog behavioural checks passed (real Groovy interpreter)"
                      : "FAILED: ${failures} checks"
if (failures != 0) System.exit(1)
"""


def main():
    jar = rp.find_groovy(None)
    program = PROGRAM + "\n" + rp.extract_helpers(SCRIPT, HELPERS) + "\n"
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "dialog_check.groovy"
        path.write_text(program, encoding="utf-8")
        cmd = jar + [str(path)]
        proc = subprocess.run(cmd, capture_output=True, text=True)
    out = (proc.stdout + proc.stderr).strip()
    print(out)
    if proc.returncode != 0 or "FAIL" in out:
        sys.exit(1)
    print("settings dialog checks passed")


if __name__ == "__main__":
    main()
