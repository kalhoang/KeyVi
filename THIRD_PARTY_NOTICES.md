# Third-party notices

This file lists every third-party dependency, data list and asset that ships with {{AppName}} or its website, with its licence (CLR-R6, CLR-R7, QA-R66). It must be complete before every public release. Adding a dependency requires a decision record in `docs/decisions/` and an entry here (QA-R24).

The project is pre-alpha. Sections marked **placeholder** are filled in by the track or person that owns the item; do not remove them.

## 1. Runtime dependencies of the app

Sparkle is the only runtime dependency (QA-R24).

### Sparkle 2.10.1

- Project: <https://github.com/sparkle-project/Sparkle>
- Used for: update checks, download, signature verification and installation (EdDSA).
- Version: **2.10.1**, pinned exactly (PLT-R910): `exactVersion` in `project.yml` and revision `ab7d71291238df6e0492143b120c9b696a35f603` in [`Config/Package.resolved`](Config/Package.resolved) ([ADR 0304](docs/decisions/0304-sparkle-version-pin.md)). The release scripts download the same version's tools (`Sparkle-2.10.1.tar.xz`, SHA-256 pinned in `scripts/publish-release`).
- Licence: MIT, with additional licences for code bundled inside Sparkle (bsdiff, sais-lite, ed25519, SUSignatureVerifier).
- Source of the notice text below: the `LICENSE` file of the Sparkle repository at tag `2.10.1`, compared line by line on 2026-11-13 (identical). Re-fetch and compare it whenever the pin changes; a pin change is a decision-record change (ADR 0304).

```text
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions 
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

## 2. Engine package dependencies

`Packages/VietnameseEngine` (MPL-2.0) depends on the Swift standard library only. `VietnameseEngineData` embeds the data listed in section 3. The test-only and tooling targets add no redistributed code.

## 3. Data: word lists and corpora

The authoritative list, with source URL, pinned version, checksum, licence, the full notice text and the way the data is transformed, lives in **[`data/NOTICES.md`](data/NOTICES.md)**, maintained by the data track together with the pinned inputs in `data/` (ENG-R810, ENG-R811). Every word-list row below points there; this file only summarises it, and the notice texts that must be reproduced (for example SCOWL's) are reproduced in `data/NOTICES.md`, not copied here, so there is one copy to keep current.

| Data | Used for | Source, version, notice | Licence | Status |
|---|---|---|---|---|
| SCOWL (Spell Checker Oriented Word Lists, Kevin Atkinson) | English lexicon for automatic restore (spec/01-engine.md section 8.2) | [`data/NOTICES.md`](data/NOTICES.md), SCOWL entry | MIT/X11-style notice that must be reproduced (ENG-R811); the data track also verifies that the chosen size levels are redistributable | Filled by the data track |
| Public gazetteers (proper-noun corpus) | `proper-nouns` corpus file | [`data/NOTICES.md`](data/NOTICES.md), gazetteer entries | Record licence per CLR-R6 | Filled by the data track |
| Hand-written lists (tech-always list, code-only tech list, ambiguity table, collisions) | Restore data and corpus | Written for this project | Same as the engine (MPL-2.0) | Original |
| Attested syllables | Tie-breaker data only | Built by a reproducible script from legal normative texts, plus reviewed additions; documents listed in [`data/NOTICES.md`](data/NOTICES.md) | Record the exact documents and the legal basis | Filled by the data track |

Rules (CLR-R6): every list needs a recorded permissive licence (MIT, BSD, Apache-2.0, CC0, CC-BY or public domain). GPL and LGPL data, including the hunspell-vi and Aspell Vietnamese lists, must not be bundled or downloaded. The syllable validator is rule-based, so no Vietnamese dictionary is needed.

## 4. Assets

- **Icons** (app icon, menu-bar template icons, DMG background): original work created for this project. No third-party icon sets are included. Record the author, date and source file of each asset here when it is added (placeholder).
- **Donation QR codes** (VietQR, MoMo): generated from the maintainer's own accounts, bundled as image files, never fetched at runtime.
- **Fonts**: none bundled by the app. The website's fonts, if any, are listed by the site track (placeholder).
- **Illustrations and screen recordings** on the website and in onboarding: created for this project (placeholder; list each item).

## 5. Website

Dependencies of the static site generator (`site/`) are development-time only and are not redistributed in the generated output unless listed here (placeholder, filled by the site track).

## 6. Documentation

- `CODE_OF_CONDUCT.md` is adapted from the [Contributor Covenant](https://www.contributor-covenant.org), version 2.1, available at <https://www.contributor-covenant.org/version/2/1/code_of_conduct.html>, licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). Community Impact Guidelines were inspired by [Mozilla's code of conduct enforcement ladder](https://github.com/mozilla/diversity).
- `CHANGELOG.md` follows the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

## 7. Development tools (not redistributed)

XcodeGen, swift-format and other build tools are used during development and CI but are not part of any shipped artefact, so they are not listed above. If a tool's output is embedded in the product, move it to a section above.
