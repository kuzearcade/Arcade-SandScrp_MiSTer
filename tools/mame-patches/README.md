# Local MAME patches

Diagnostic patches applied to the local MAME source tree (`~/mame`, which is
gitignored — see `.gitignore`). They are kept here because that tree is not
part of this repository's history, so a re-clone would silently lose them and
the measurements that depend on them could not be reproduced.

None of these are for upstream. Each is **env-gated and inert by default**, so
a patched MAME still renders stock output unless the variable is set.

## `sandscrp-ym-isolation.patch`

Adds `SS_YM_ISO` to `src/mame/kaneko/sandscrp.cpp`:

| `SS_YM_ISO` | effect |
|---|---|
| unset | stock behaviour, all four YM2203 streams at 0.5 plus the OKI |
| `fm` | routes only the FM stream (index 3), OKI muted |
| `ssg` | routes only the three SSG streams (0..2), OKI muted |

MAME rotates ymfm's outputs so the SSG channels are 0..2 and FM is 3
(`ymfm_mame.h`). Without this there is no way to measure MAME's own FM/SSG
balance on identical content, and SS-10 explicitly warns against reasoning
about the two from the mix alone.

Apply with:

    cd ~/mame && patch -p0 < .../tools/mame-patches/sandscrp-ym-isolation.patch

then rebuild only that driver:

    make SUBTARGET=arcade SOURCES=src/mame/kaneko/sandscrp.cpp -j$(nproc)

which produces `~/mame/arcade` — a binary containing **only** the three
sandscrp sets, not a full MAME. Use `~/mame/mame` for anything else.

**MAME must run with SDL told not to touch real devices**, or it hangs in
device init with zero CPU and no output, even with `-video none -sound none`:

    export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy

and never give MAME a pipe on stdout — it hides every error message.
