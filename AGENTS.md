# AGENTS.md — MNIST ZK-SNARK (Circom + snarkjs)

## Project

ZK-SNARK (Groth16, BN254) proving correct MNIST digit classification by a 3-layer MLP
(784→128→64→10). Circuit written in Circom 2.1.6; model trained in TensorFlow/Keras.

Only **`predicted_class`** is public; pixels + all weights and biases are private.

## Key files

| File | Role |
|------|------|
| `Main.circom` | The circuit: DenseReLU x2 + DenseLinear + VerifyArgMax |
| `rede_mnist.py` | TF/Keras model → exports `input.json` with weights scaled by 10⁶ |
| `Main_js/` | Compiled WASM witness calculator + generated artifacts |
| `Main_cpp/` | Compiled C++ witness calculator (with `Makefile`) |
| `*.zkey` | Phase 2 circuit-specific proving keys |
| `pot20_*.ptau` | Phase 1 universal powers of tau |
| `verification_key.json` | Public verification key |

## Pipeline (10 steps)

```bash
# 1. Compile circuit
circom Main.circom --r1cs --wasm --sym --c

# 2. Generate witness (re-run on new input only)
node Main_js/generate_witness.js Main_js/Main.wasm Main_js/input.json Main_js/witness.wtns

# 3–5. Phase 1 trusted setup (universal, one-time)
snarkjs powersoftau new bn128 20 pot20_0000.ptau -v
snarkjs powersoftau contribute pot20_0000.ptau pot20_0001.ptau
snarkjs powersoftau prepare phase2 pot20_0001.ptau pot20_final.ptau -v

# 6–8. Phase 2 trusted setup (re-run if circuit changes)
snarkjs groth16 setup Main.r1cs pot20_final.ptau Main_0000.zkey
snarkjs zkey contribute Main_0000.zkey Main_0001.zkey
snarkjs zkey export verificationkey Main_0001.zkey verification_key.json

# 9. Prove (re-run on new input only)
snarkjs groth16 prove Main_0001.zkey Main_js/witness.wtns Main_js/proof.json Main_js/public.json

# 10. Verify
snarkjs groth16 verify verification_key.json Main_js/public.json Main_js/proof.json
```

**Dependency rule**: change circuit → redo steps 1 + 6–10. Change input only → redo steps 2 + 9–10.

## Critical gotchas

- **Scale factor = 10⁶**. `X*W` lands at 10¹²; `ReLUAndScale` divides by 10⁶ back to 10⁶ for the next layer. All biases are also multiplied by 10⁶ before accumulation.
- **`<--` for division**: R1CS can't constrain integer division. `out <-- relu_val \ 1000000` is unconstrained; a separate constraint `relu_val === out * 1000000 + rem` enforces correctness. Both must be present.
- **ReLU via BN254 bit 253**: negative values in BN254 field are `p - x`. `Num2Bits(254)` extracts bit 253 (sign). If 1, the value is clamped to 0.
- **ArgMax uses `IsEqual`** for each class index; dynamic indexing is not possible in Circom. Exactly one class must match (`total_chosen === 1`).
- **Input format**: all numbers are strings in `input.json` (scaled integers).
- **No tests, no lint, no CI**. This is a research/educational project with no test framework, formatter config, or CI pipeline.
