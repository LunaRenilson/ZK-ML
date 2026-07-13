## Controle de Escala

Como redes neurais usam números de ponto flutuante (decimais) e o Circom só aceita inteiros, o script Python multiplicou todos os parâmetros por 1.000.000 ($10^6$) antes de exportar, mantendo precisão de ~6 casas decimais.

Quando a rede neural faz a operação $X×W+B$:
1. O input X está na escala $10^6$.
2. O peso W está na escala $10^6$.
3. A multiplicação $X×W$ joga o resultado para a escala $10^{12}$.  

Se deixarmos o número crescer assim a cada camada, ele rapidamente estoura o tamanho máximo permitido. Por isso, após a ativação ReLU, o código divide o valor por 1.000.000 para fazê-lo voltar para a escala $10^6$, deixando-o pronto para a próxima camada.

## Uso de `<--` ao invés de `<==`?

No Circom, a seta tradicional `<==` faz duas coisas ao mesmo tempo:

1. Atribui um valor a uma variável
2. cria uma restrição matemática (uma equação que precisa ser provada).

O problema é que o sistema R1CS não sabe fazer divisão inteira (`\`) nem resto de divisão (`%`) diretamente. Ele só entende somas, subtrações e multiplicações simples.

Se você tentássemos escrever `out <== relu_val \ 1000000;`, o compilador do Circom daria um erro na hora. Para contornar isso, o operador <-- apenas calcula o valor (ele diz para o gerador de testemunhas: "faça essa conta de divisão normal e guarde o resultado aqui"). 

Para gerar a restrição em cima dessa operação e evitar que um provador malicioso falsifique a multiplicação, adicionamos a restrição: `relu_val === out * 1000000 + rem;`

Se o provador tentar inventar um valor falso para out ou para rem, a igualdade se torna falsa, a restrição quebra, e a prova criptográfica é rejeitada na hora.

## ReLU

O objetivo dessa camada é aplicar a equação dos neurônios: $$Y = \text{ReLU}(X \cdot W + B)$$

Sinais adotados para esse template:
- `in[n_in]`: Um vetor contendo as ativações vindas da camada anterior.
- `weights[n_out][n_in]`: Matriz de pesos trasposta. Assim, `weight[i]` possui todos os pesos conectados ao neurônio `i`
- `bias[n_out]`: Vetor de viéses, um para cada neurônio
- `out[n_out]`: Vetor de saídas após o ReLU

Além disso, outro detalhe importante é a necessidade do vetor `mult[n_out][n_in]` para guardar as multiplicações intermediárias, pois o circom não aceita operações não lineares

## Private e public inputs esperados no input.json

**Público:** 
- predicted_class (input de main via component main {public [predicted_class]})

**Privados:**
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
Entrando na verificaÃ§Ã£o do ArgMax...
predicted_class:  7
```

---

## Explicação Detalhada de Cada Comando

### FASE I: Compilação e Execução Local (O Grafo e os Dados)

**1. `circom Main.circom --r1cs --wasm --sym --c`**

- **O que faz:** Traduz o código estrutural em Circom para um sistema de equações matemáticas.
- **Dependência:** Estritamente do código/arquitetura. Ele não sabe qual imagem você vai rodar e nem quais são os pesos finais. Se você alterar um único neurônio da rede, precisará rodar esse comando de novo.

**2. `node generate_witness.js Main.wasm input.json witness.wtns`**

- **O que faz:** Executa a inferência da rede neural propriamente dita dentro do motor WebAssembly. Ele calcula o valor exato de cada multiplicação e soma da sua rede para aquela imagem específica.
- **Dependência:** Do código e do Input completo (Pesos + Imagem). Cada vez que você for classificar uma imagem nova, ou se mudar os pesos da rede, você precisará gerar um witness.wtns novo.

### FASE II: Trusted Setup - Fase 1 (Universal / Independente)

> **Nota:** Os passos 3, 4 e 5 fazem parte da "Fase 1" do Trusted Setup. Eles são universais. Você pode baixar esses arquivos prontos da internet (da comunidade Ethereum, por exemplo) e nunca precisar executá-los na mão, pois eles não sabem nada sobre redes neurais.

**3. `snarkjs powersoftau new bn128 20 pot20_0000.ptau -v`**

- **O que faz:** Cria um arquivo de potências de Tau inicial usando a curva elíptica bn128. O número 20 indica a magnitude do circuito ($2^{20} = 1.048.576$ restrições matemáticas máximas). Como a sua rede gerou cerca de 166 mil restrições, o tamanho 20 comporta o seu circuito perfeitamente com folga.
- **Dependência:** Universal. Não depende do seu código e nem do seu input.

**4. `snarkjs powersoftau contribute pot20_0000.ptau pot20_0001.ptau ...`**

- **O que faz:** Adiciona uma "contribuição" de entropia (aleatoriedade). Você digita caracteres aleatórios no teclado para gerar um segredo criptográfico que será destruído logo em seguida (conhecido como Toxic Waste).
- **Dependência:** Universal. (Nota: no seu comando original havia um pequeno erro de digitação de nome de arquivo pot12, o correto para manter a consistência é usar pot20 em toda a cadeia).

**5. `snarkjs powersoftau prepare phase2 pot20_0001.ptau pot20_final.ptau -v`**

- **O que faz:** Pega o arquivo de aleatoriedade acumulada, realiza computações baseadas em transformadas rápidas de Fourier e sela a Fase 1, gerando o pot20_final.ptau.
- **Dependência:** Universal.

### FASE III: Trusted Setup - Fase 2 (Específica do Circuito)

**6. `snarkjs groth16 setup Main.r1cs pot20_final.ptau Main_0000.zkey`**

- **O que faz:** Pega o espaço matemático gigante e universal (pot20_final.ptau) e o "recorta" cirurgicamente para encaixar exatamente no formato das restrições da sua rede neural (Main.r1cs). Ele gera a primeira chave de prova (.zkey).
- **Dependência:** Do Circuito/Código. Não depende do input.

**7. `snarkjs zkey contribute Main_0000.zkey Main_0001.zkey ...`**

- **O que faz:** Adiciona uma nova camada de aleatoriedade humana, mas agora especificamente direcionada para a chave da sua rede neural. Isso garante que nem mesmo quem criou o ecossistema original consiga falsificar uma prova para o seu circuito.
- **Dependência:** Do Circuito/Código.

**8. `snarkjs zkey export verificationkey Main_0001.zkey verification_key.json`**

- **O que faz:** Pega a chave de criptografia consolidada e extrai dela apenas a parte pública necessária para realizar checagens (a chave de verificação). Esse arquivo é minúsculo e é ele que será enviado para o cliente ou para um Smart Contract na blockchain.
- **Dependência:** Do Circuito/Código.

### FASE IV: O Ecossistema de Prova (Operação em Tempo de Execução)

**9. `snarkjs groth16 prove Main_0001.zkey witness.wtns proof.json public.json`**

- **O que faz:** Pega a história da computação da sua rede neural (witness.wtns), mistura com a chave de prova do circuito e aplica os fatores de cegamento (blinding factors do artigo do Pinocchio). Ele cospe dois arquivos: a prova criptográfica ultra-compacta (proof.json) e os inputs públicos (public.json, que contém apenas o seu predicted_class).
- **Dependência:** Do Input (via Witness). É executado pelo Provedor toda vez que uma nova inferência precisa ser provada.

**10. `snarkjs groth16 verify verification_key.json public.json proof.json`**

- **O que faz:** O Verificador pega a chave pública do circuito, a classe que você diz ter encontrado e o arquivo de prova. Ele roda o pareamento de curvas elípticas. Se retornar OK, a matemática garante que você rodou a rede com a imagem e os pesos corretos.
- **Dependência:** Apenas da Prova e do Input Público. Essa etapa roda em milissegundos e não tem acesso aos pesos privados da rede e nem à imagem original.

---

## O que acontece ao Falsificar resultado da rede?

Isso dependerá da forma como o resultado foi falsificado. Aqui, abordaremos dois cenários distintos.

### Cenário A: O Ataque de Alteração do Input Público

Este é o principal vetor que a Etapa 10 intercepta. Imagine que o provador malicioso decida jogar de forma limpa no início:

- Ele insere a imagem do dígito "5" e coloca "predicted_class": "5" no seu JSON.
- A Etapa 2 roda perfeitamente e gera a testemunha legítima.
- A Etapa 9 gera um proof.json válido e um arquivo public.json contendo o valor ["5"].
- Antes de enviar os arquivos para o Verificador, o provador abre o arquivo public.json manualmente com um bloco de notas e altera o valor de "5" para "3".

Quando o Verificador executa a Etapa 10, ele pega a prova (que foi criptografada matematicamente baseada no número 5) e tenta casá-la com o input público adulterado (o número 3) usando o emparelhamento de curvas elípticas (pairing). A igualdade criptográfica não vai bater por causa de um único dígito, e o comando retornará Verification failed

**Resultado:** `[ERROR] snarkJS: Invalid proof`


### Cenário B: Alteração do input.json (Pesos, pixels da imagem e predicted_class)

(Exemplo: A rede processa o dígito "5", mas você força no JSON que a predicted_class é "3")

O fluxo travará na **Etapa 2 (Geração do Witness)**:

Quando o comando `node generate_witness.js...` for executado, o motor do Circom vai processar os pixels, calcular que o maior score era do neurônio "5", mas verá que o predicted_class fornecido foi "3". Como no circuito nós usamos restrições estritas (`===`), o calculador de testemunhas vai detectar a violação matemática e retornará um erro de constraint (ex: `Constraint failed`), interrompendo a execução imediatamente.

**Saída resultate**: 
```
Entrando na camada 1 (DenseReLU)...
Maior valor em DenseReLU:  564307073262
Entrando na camada 2 (DenseReLU)...
Maior valor em DenseReLU:  2304239438727
Entrando na camada 3 (DenseLinear)...
Maior valor em DenseLinear:  3959687853400
Entrando na verificaÃ§Ã£o do ArgMax...
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
**Conclusão:** O arquivo `witness.wtns` sequer será gerado. Você não conseguirá nem chegar nas etapas 9 e 10, o que prova que o seu circuito é perfeitamente seguro contra outputs falsificados.