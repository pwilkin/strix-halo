# Strix Halo × Qwen3.8

Source for the installer and GitHub Pages guide at:

<https://pwilkin.github.io/strix-halo/>

The project installs a pinned, reproducible Qwen3.8-27B stack for AMD Strix Halo (`gfx1151`):

- custom ROCr and HIP from [`pwilkin/rocm-systems:ilintar-experiments`](https://github.com/pwilkin/rocm-systems/tree/ilintar-experiments);
- llama.cpp from [`pwilkin/llama.cpp:strix-halo`](https://github.com/pwilkin/llama.cpp/tree/strix-halo), including the UMA scheduler ring and optimized ROCm TOP_K path;
- the calibrated IQ4_XS/Q8 target and IQ4_XS DFlash2 sidecar from [`ilintar/qwen3.8-27b-gguf-strix-halo`](https://huggingface.co/ilintar/qwen3.8-27b-gguf-strix-halo);
- Bartowski's matching BF16 Qwen3.8-27B vision projector;
- launchers in `~/.local/bin` for the complete model and for arbitrary `llama-server` commands under the custom runtime.

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pwilkin/strix-halo/main/install.sh)
```

Process substitution is intentional: unlike `curl | bash`, it leaves stdin attached to the terminal so the installer can ask where to store the models. The default is `~/.models`.

Inspect first if desired:

```bash
curl -fsSL https://raw.githubusercontent.com/pwilkin/strix-halo/main/install.sh -o install.sh
less install.sh
bash install.sh
```

## Installed commands

```bash
qwen3.8-strix-halo-server
```

starts the selected target, DFlash2 draft, and vision projector with the custom retained-PM4 runtime.

```bash
llama-server-strix-halo -m /path/to/model.gguf [options]
```

runs an arbitrary model with the custom HIP and ROCr library overrides.

## Repository contents

- `install.sh` — portable single-file installer.
- `index.html`, `styles.css`, `script.js` — dependency-free GitHub Pages site.
- `data/benchmarks.json` — machine-readable benchmark summary.

The benchmark page deliberately labels protocol differences. Token rates from different prompts, context depths, quantizations, engines, power limits, and speculative acceptance levels are not interchangeable.

The primary comparison is a matched 31,497-token reproduction on one Radeon 8060S. Each stack processed the same source-file prompt and generated 256 tokens in a palindrome-ordered, two-pass bracket:

| Reproduced stack | Prompt t/s | Decode t/s | Our margin |
| --- | ---: | ---: | ---: |
| Selected IQ4_XS + IQ4_XS DFlash2, custom ROCm retained PM4 | 256.84 | 26.256 | fastest |
| ROCmFP4 FAST + FP4 DFlash2, Nathan-derived Vulkan stack | 215.64 | 23.168 | +13.33% |
| Same selected IQ4_XS models, Nathan-derived Vulkan stack | 219.67 | 20.942 | +25.38% |

The aggregated and per-run values are published in `data/reproduction-results.json`.

## Support

If this work is useful, support future experiments at <https://buymeacoffee.com/ilintar>.

## License

The installer and site are MIT licensed. llama.cpp, ROCm, Qwen, DFlash2, model files, and third-party benchmark material remain under their respective licenses and terms.
