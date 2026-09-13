# Offline voice components

CosyVoice 3 (FunAudioLLM/QwenAudio) and its speech-swift conversion/runtime are Apache-2.0. MLX Swift and MLX are MIT. The bundled Japanese frontend uses MeCab-Swift (MIT), MeCab (BSD option) and IPADic (NAIST/ICOT notice); license texts are included here.

The fixed voice was prepared from LJ Speech 1.1 clip LJ025-0076, an 8.397-second public-domain recording. Source and public-domain statement: https://keithito.com/LJ-Speech-Dataset/ . The app includes precomputed voice conditioning; no reference encoder or user voice recording is needed. The reference SHA-256 is b31133c05e9667a27db5be539ca089aa99e95ca7bef52040c902ff781680873a.

Model, runtime and preparation details: docs/research/cosyvoice3-integration.md in the Phrayo source repository.
