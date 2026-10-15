# ZK-MNIST: Zero-Knowledge Proof for Neural Network Inference with Circom

Zero-knowledge proof system (zk-SNARK) that verifies the correct classification of MNIST digits by a 3-layer MLP (784→128→64→10) without revealing the weights, biases, or input image. Only the predicted digit (`predicted_class`) is public; all remaining 110,170 parameters are private. Implemented in Circom 2.1.6 with the Groth16 protocol on the BN254 curve.

## Scale Control

Since neural networks use floating-point numbers (decimals) and Circom only accepts integers, the Python script multiplied all parameters by 1,000,000 ($10^6$) before exporting, maintaining a precision of ~6 decimal places.

When the neural network performs the $X \cdot W + B$ operation:
1. Input X is on the $10^6$ scale.
2. Weight W is on the $10^6$ scale.
3. The multiplication $X \cdot W$ scales the result up to $10^{12}$.

If we allow the number to grow like this at each layer, it quickly exceeds the maximum allowed size. Therefore, after the ReLU activation, the code divides the value by 1,000,000 to scale it back down to $10^6$, preparing it for the next layer.

## Why Use `<--` Instead of `<==`?

In Circom, the traditional `<==` arrow performs two actions simultaneously:

1. Assigns a value to a variable
2. Creates a mathematical constraint (an equation that must be proven).

The issue is that the R1CS system cannot perform integer division (`\`) or modulo remainder (`%`) directly. It only understands simple additions, subtractions, and multiplications.

If you tried to write `out <== relu_val \ 1000000;`, the Circom compiler would throw an error immediately. To bypass this, the `<--` operator merely computes the value (it instructs the witness generator: "perform this standard division calculation and store the result here").

To generate the constraint on top of this operation and prevent a malicious prover from forging the multiplication, we add the constraint: `relu_val === out * 1000000 + rem;`

If the prover tries to invent a false value for `out` or `rem`, the equality becomes false, the constraint fails, and the cryptographic proof is immediately rejected.

## ReLU

The objective of this layer is to apply the neuron equation: $$Y = \text{ReLU}(X \cdot W + B)$$

Signals adopted for this template:
- `in[n_in]`: A vector containing activations from the previous layer.
- `weights[n_out][n_in]`: Transposed weight matrix. Thus, `weight[i]` contains all weights connected to neuron `i`.
- `bias[n_out]`: Bias vector, one for each neuron.
- `out[n_out]`: Output vector after ReLU.

In addition, another important detail is the need for the `mult[n_out][n_in]` vector to store intermediate multiplications, as Circom does not accept non-linear operations directly.

## Private and Public Inputs Expected in input.json

**Public:**
- predicted_class (input of main via `component main {public [predicted_class]}`)

**Private:**
- in[784]
- weights_1[128][784]
- bias_1[128]
- weights_2[64][128]
- bias_2[64]
- weights_3[10][64]
- bias_3[10]

## Compilation and Generation Process

As a result of the compilation we will also obtain **programs to compute the witness**
`circom Main.circom --r1cs --wasm --sym --c` which results in:
```
template instances: 12
non-linear constraints: 173184
linear constraints: 1385
public inputs: 1
private inputs: 110170
public outputs: 0
wires: 284154
labels: 395911
```

---

Before creating the proof, we need to **calculate all the signals of the circuit** that match all the constraints of the circuit:
`node generate_witness.js multiplier2.wasm input.json witness.wtns`, which results in:
```
Entrando na camada 1 (DenseReLU)...
Maior valor em DenseReLU:  564307073262
Entrando na camada 2 (DenseReLU)...
Maior valor em DenseReLU:  2304239438727
Entrando na camada 3 (DenseLinear)...
Maior valor em DenseLinear:  3959687853400
Entrando na verificação do ArgMax...
predicted_class:  7
```

---

## Detailed Explanation of Each Command

### PHASE I: Compilation and Local Execution (The Graph and Data)

**1. `circom Main.circom --r1cs --wasm --sym --c`**

- **What it does:** Translates structural Circom code into a system of mathematical equations.
- **Dependency:** Strictly dependent on the code/architecture. It does not know which image you will run or what the final weights are. If you modify a single neuron in the network, you will need to re-run this command.

**2. `node generate_witness.js Main.wasm input.json witness.wtns`**

- **What it does:** Executes the neural network inference itself inside the WebAssembly engine. It calculates the exact value of every multiplication and addition in your network for that specific image.
- **Dependency:** Dependent on the code and the complete Input (Weights + Image). Every time you classify a new image, or if you change the network weights, you will need to generate a new `witness.wtns`.

### PHASE II: Trusted Setup - Phase 1 (Universal / Independent)

> **Note:** Steps 3, 4, and 5 are part of "Phase 1" of the Trusted Setup. They are universal. You can download these files pre-generated from the internet (e.g., from the Ethereum community) and never need to run them manually, as they contain no information about neural networks.

**3. `snarkjs powersoftau new bn128 20 pot20_0000.ptau -v`**

- **What it does:** Creates an initial Powers of Tau file using the bn128 elliptic curve. The number 20 specifies the circuit magnitude ($2^{20} = 1,048,576$ maximum mathematical constraints). Since your network generated around 166,000 constraints, size 20 comfortably accommodates your circuit with plenty of margin.
- **Dependency:** Universal. Does not depend on your code or your input.

**4. `snarkjs powersoftau contribute pot20_0000.ptau pot20_0001.ptau ...`**

- **What it does:** Adds an entropy (randomness) "contribution". You type random characters on the keyboard to generate a cryptographic secret that will be destroyed immediately afterward (known as Toxic Waste).
- **Dependency:** Universal. (Note: in your original command there was a minor typo in a filename referencing `pot12`; for consistency, `pot20` should be used throughout the chain).

**5. `snarkjs powersoftau prepare phase2 pot20_0001.ptau pot20_final.ptau -v`**

- **What it does:** Takes the accumulated randomness file, performs computations based on Fast Fourier Transforms (FFT), and seals Phase 1, generating `pot20_final.ptau`.
- **Dependency:** Universal.

### PHASE III: Trusted Setup - Phase 2 (Circuit-Specific)

**6. `snarkjs groth16 setup Main.r1cs pot20_final.ptau Main_0000.zkey`**

- **What it does:** Takes the giant, universal mathematical space (`pot20_final.ptau`) and surgically "trims" it to fit the exact constraint structure of your neural network (`Main.r1cs`). It generates the initial proving key (`.zkey`).
- **Dependency:** Dependent on the Circuit/Code. Does not depend on input.

**7. `snarkjs zkey contribute Main_0000.zkey Main_0001.zkey ...`**

- **What it does:** Adds another layer of human randomness, but now specifically targeted at your neural network's key. This guarantees that not even the creator of the original setup can forge a proof for your circuit.
- **Dependency:** Dependent on the Circuit/Code.

**8. `snarkjs zkey export verificationkey Main_0001.zkey verification_key.json`**

- **What it does:** Takes the consolidated cryptographic key and extracts only the public portion required to perform verifications (the verification key). This file is tiny and is what gets sent to the client or deployed to a blockchain Smart Contract.
- **Dependency:** Dependent on the Circuit/Code.

### PHASE IV: Proving Ecosystem (Runtime Operation)

**9. `snarkjs groth16 prove Main_0001.zkey witness.wtns proof.json public.json`**

- **What it does:** Takes the execution history of your neural network (`witness.wtns`), combines it with the circuit proving key, and applies blinding factors (from the Pinocchio protocol paper). It outputs two files: the ultra-compact cryptographic proof (`proof.json`) and the public inputs (`public.json`, containing only your `predicted_class`).
- **Dependency:** Dependent on Input (via Witness). Executed by the Prover every time a new inference needs to be proven.

**10. `snarkjs groth16 verify verification_key.json public.json proof.json`**

- **What it does:** The Verifier takes the circuit's verification key, the claimed class, and the proof file. It runs elliptic curve pairings. If it returns OK, mathematics guarantees that you ran the network with the correct image and weights.
- **Dependency:** Dependent only on the Proof and Public Input. This step executes in milliseconds and has no access to private network weights or the original image.

---

## What Happens When Forging Network Results?

This depends on how the result was forged. Here we cover two distinct scenarios.

### Scenario A: Public Input Modification Attack

This is the main attack vector intercepted by Step 10. Imagine a malicious prover initially plays clean:

- Inserts the digit "5" image and sets `"predicted_class": "5"` in the JSON.
- Step 2 runs perfectly and generates a legitimate witness.
- Step 9 generates a valid `proof.json` and a `public.json` containing the value `["5"]`.
- Before sending files to the Verifier, the prover manually opens `public.json` in a text editor and changes "5" to "3".

When the Verifier runs Step 10, it takes the proof (cryptographically calculated based on number 5) and attempts to match it against the tampered public input (number 3) via elliptic curve pairing. The cryptographic equality fails due to a single mismatching digit, returning "Verification failed".

**Result:** `[ERROR] snarkJS: Invalid proof`

### Scenario B: Modification of input.json (Weights, Image Pixels, or predicted_class)

(Example: The network processes the digit "5", but you force `"predicted_class": "3"` inside the JSON)

The workflow will halt at **Step 2 (Witness Generation)**:

When running `node generate_witness.js...`, the Circom engine processes pixel inputs, calculates that the highest score corresponds to neuron "5", but observes that the provided `predicted_class` was "3". Since strict constraints (`===`) are enforced in the circuit, the witness calculator detects a mathematical violation and throws a constraint failure error (e.g., `Assert Failed`), halting execution immediately.

**Resulting Output:**
```
Entrando na camada 1 (DenseReLU)...
Maior valor em DenseReLU:  564307073262
Entrando na camada 2 (DenseReLU)...
Maior valor em DenseReLU:  2304239438727
Entrando na camada 3 (DenseLinear)...
Maior valor em DenseLinear:  3959687853400
Entrando na verificação do ArgMax...
/l/disk0/renilson/projects/033/Main_js/witness_calculator.js:166
                    throw new Error(err);
                          ^

Error: Error: Assert Failed.
Error in template VerifyArgMax_10 line: 161
Error in template MNIST_11 line: 206

    at /l/disk0/renilson/projects/033/Main_js/witness_calculator.js:166:27
    at Array.forEach (<anonymous>)
    at WitnessCalculator._doCalculateWitness (/l/disk0/renilson/projects/033/Main_js/witness_calculator.js:141:14)
    at WitnessCalculator.calculateWTNSBin (/l/disk0/renilson/projects/033/Main_js/witness_calculator.js:216:20)
    at /l/disk0/renilson/projects/033/Main_js/generate_witness.js:16:38

Node.js v22.21.0
```

**Conclusion:** The `witness.wtns` file will not even be generated. You will not be able to proceed to Steps 9 and 10, proving that your circuit is completely secure against forged outputs.
