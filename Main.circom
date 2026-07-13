pragma circom 2.1.6;

include "./node_modules/circomlib/circuits/comparators.circom";

// ==========================================
// 1. COMPONENTE RELU E REDUÇÃO DE ESCALA
// ==========================================
    template ReLUAndScale() {
        signal input in;   // Escala 10^12, resultado de X*W+B
        signal output out; // Escala 10^6 para a próxima camada

        // Detecta sinal usando o bit 253 da representação em bits.
        // Valores negativos em BN254 aparecem como p - x e têm bit 253 = 1.
        component bits = Num2Bits(254);
        bits.in <== in;

        signal sign <== bits.out[253]; // 1 se negativo, 0 se positivo

        // ReLU: negativa vira 0, positiva fica igual.
        signal relu_val;
        relu_val <== (1 - sign) * in;

        // Reduz de escala 10^12 para 10^6.
        out <-- relu_val \ 1000000;
        signal rem <-- relu_val % 1000000;

        // Verifica que resto é um inteiro pequeno e válido.
        component checkBits = Num2Bits(32);
        checkBits.in <== rem;

        relu_val === out * 1000000 + rem;

        component lt = LessThan(32);
        lt.in[0] <== rem;
        lt.in[1] <== 1000000;
        lt.out === 1;
    }


// ==========================================
// 2. CAMADA DENSA COM ATIVAÇÃO RELU
// ==========================================
template DenseReLU(n_in, n_out) {
    signal input in[n_in];
    signal input weights[n_out][n_in];
    signal input bias[n_out];
    signal output out[n_out];

    // Armazena multiplicações intermediárias (para manter a linearidade)
    signal mult[n_out][n_in];
    component relu[n_out];

    // Armazena maior valor para debug
    var maior_valor = 0;

    for (var i = 0; i < n_out; i++) {
        var lin_sum = bias[i] * 1000000; // Eleva o bias de 10^6 para 10^12 para igualar a (X * W)
        
        // Aplicando X * W + B para cada neurônio da camada
        for (var j = 0; j < n_in; j++) {
            // multiplicação intermediaria
            mult[i][j] <== in[j] * weights[i][j]; // Escala 10^12

            // Salva maior valor para debug
            if (mult[i][j] > maior_valor) {
                maior_valor = mult[i][j];
            }

            lin_sum += mult[i][j];
        }

        // Aplica ReLU e redução de escala
        relu[i] = ReLUAndScale();
        relu[i].in <== lin_sum;
        out[i] <== relu[i].out;
    }
    // Imprimindo maior valor para debug
    log("Maior valor em DenseReLU: ", maior_valor);
}

// ==========================================
// 3. CAMADA DENSA LINEAR (ÚLTIMA CAMADA / LOGITS)
// ==========================================
template DenseLinear(n_in, n_out) {
    signal input in[n_in];
    signal input weights[n_out][n_in];
    signal input bias[n_out];
    signal output out[n_out]; // Mantém em escala 10^12 para a comparação final

    signal mult[n_out][n_in];

    // salva maior valor para debug
    var maior_valor = 0;
    
    for (var i = 0; i < n_out; i++) {
        var lin_sum = bias[i] * 1000000;
        for (var j = 0; j < n_in; j++) {
            // Isolando restrição quadrática
            mult[i][j] <== in[j] * weights[i][j]; // Escala 10^12
            lin_sum += mult[i][j];

            // Salva maior valor para debug
            if (mult[i][j] > maior_valor) {
                maior_valor = mult[i][j];  
            }
        }
        out[i] <== lin_sum;
    }
    // Imprimindo maior valor para debug
    log("Maior valor em DenseLinear: ", maior_valor);
}

// ==========================================
// 4. VERIFICAÇÃO DO ARGMAX (PROVAR A CLASSIFICAÇÃO)
// ==========================================
template VerifyArgMax(n_classes) {
    signal input scores[n_classes];
    signal input predicted_class;

    // O provador nos diz qual é a classe (predicted_class).
    // Checamos se o score dela é maior ou igual a todos os outros.
    
    // Como não podemos indexar dinamicamente scores[predicted_class], usamos seletores:
    component is_chosen[n_classes];
    
    // var chosen_score = 0;
    signal chosen_score_parts[n_classes]; // Para somar o score da classe escolhida
    var total_chosen = 0;

    // Verificando se predicted_class é igual a cada índice e acumulando o score correspondente
    for (var i = 0; i < n_classes; i++) {

        // is_chosen[i] será 1 se predicted_class == i, e 0 caso contrário.
        is_chosen[i] = IsEqual();
        is_chosen[i].in[0] <== predicted_class;
        is_chosen[i].in[1] <== i;

        // Se is_chosen[i] for 1, então scores[i] é o score escolhido. Caso contrário, contribui com 0.
        chosen_score_parts[i] <== is_chosen[i].out * scores[i];
        total_chosen += is_chosen[i].out;
    }
    
    // Verificando se exatamente um índice foi escolhido
    total_chosen === 1; 

    // obtendo o score da classe escolhida
    var lin_sum = 0;
    for (var i = 0; i < n_classes; i++) {
        lin_sum += chosen_score_parts[i];
    }

    // Garante que chosen_score >= scores[i] para todas as classes
    component signBits[n_classes];
    for (var i = 0; i < n_classes; i++) {

        // Usa o bit mais significativo para detectar negativo em BN254.
        signBits[i] = Num2Bits(254);
        signBits[i].in <== lin_sum - scores[i];

        // Se a diferença for negativa, bit 253 será 1.
        signBits[i].out[253] === 0;
    }
}

// ==========================================
// 5. COMPONENTE PRINCIPAL (MÁSCARA DA REDE)
// ==========================================
template MNIST() {
    // Inputs Públicos
    signal input predicted_class;

    // Inputs Privados
    signal input in[784];
    signal input weights_1[128][784];
    signal input bias_1[128];
    signal input weights_2[64][128];
    signal input bias_2[64];
    signal input weights_3[10][64];
    signal input bias_3[10];

    // Camada 1: Dense 128 + ReLU
    log("Entrando na camada 1 (DenseReLU)...");
    component layer1 = DenseReLU(784, 128);
    layer1.in <== in;
    layer1.weights <== weights_1;
    layer1.bias <== bias_1;

    // Camada 2: Dense 64 + ReLU
    log("Entrando na camada 2 (DenseReLU)...");
    component layer2 = DenseReLU(128, 64);
    layer2.in <== layer1.out;
    layer2.weights <== weights_2;
    layer2.bias <== bias_2;

    // Camada 3: Dense 10 (Linear / Saída dos Logits)
    log("Entrando na camada 3 (DenseLinear)...");
    component layer3 = DenseLinear(64, 10);
    layer3.in <== layer2.out;
    layer3.weights <== weights_3;
    layer3.bias <== bias_3;

    // Verificação Final do ArgMax
    log("Entrando na verificação do ArgMax...");
    component argmax = VerifyArgMax(10);
    argmax.scores <== layer3.out;
    argmax.predicted_class <== predicted_class;
    log("predicted_class: ", predicted_class);
}

component main {public [predicted_class]} = MNIST();