// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VetNFT.sol";

/// @title VetGovernance — Governança simples para aprovar ou rejeitar veterinários
/// @notice Veterinário solicita cadastro, governança vota e, se aprovado, NFT é mintado
/// @dev Para funcionar, este contrato precisa estar configurado como `governance` no
///      VetNFT (via setGovernance), pois é ele quem chama registerVetByGovernance.
contract VetGovernance {

    /// @notice Estado de uma solicitação de cadastro
    enum Status {
        PENDENTE,  // aguardando votação / finalização
        APROVADO,  // aprovado: NFT mintado no VetNFT
        REJEITADO  // rejeitado: sem quorum ou maioria contra
    }

    /// @notice Solicitação de cadastro feita por um veterinário
    struct VetRequest {
        address vet;       // endereço solicitante
        string nome;       // nome do veterinário
        string crmv;       // registro profissional (CRMV)
        string cidade;     // cidade de atuação
        string bairro;     // bairro de atuação
        string telefone;   // telefone de contato
        uint256 votosSim;  // contagem de votos a favor
        uint256 votosNao;  // contagem de votos contra
        uint256 deadline;  // timestamp limite para votação
        Status status;     // estado atual da solicitação
        bool exists;       // flag para distinguir solicitação inexistente de uma zerada
    }

    VetNFT public vetNFT; // contrato de credenciais onde o NFT será mintado

    uint256 public requestCounter;       // contador incremental de solicitações
    uint256 public votingPeriod = 3 days; // duração padrão da janela de votação
    uint256 public quorumMinimo = 1;     // mínimo de votos totais para validar a votação

    mapping(uint256 => VetRequest) public requests;                 // id => solicitação
    mapping(uint256 => mapping(address => bool)) public jaVotou;     // id => (governador => votou?)
    mapping(address => bool) public governadores;                   // endereços com direito a voto

    address public owner; // dono do contrato (gerencia governadores e parâmetros)

    /// @notice Emitido quando um vet solicita cadastro
    event VetSolicitou(
        uint256 indexed requestId,
        address indexed vet,
        string nome,
        string crmv,
        string cidade,
        string bairro,
        string telefone
    );

    /// @notice Emitido a cada voto registrado
    event VotoRegistrado(
        uint256 indexed requestId,
        address indexed voter,
        bool aprovado
    );

    /// @notice Emitido quando uma solicitação é aprovada e o NFT é mintado
    event VetAprovado(
        uint256 indexed requestId,
        address indexed vet
    );

    /// @notice Emitido quando uma solicitação é rejeitada
    event VetRejeitado(
        uint256 indexed requestId,
        address indexed vet
    );

    /// @notice Restringe a chamada ao owner do contrato
    modifier onlyOwner() {
        require(msg.sender == owner, "Apenas owner");
        _;
    }

    /// @notice Restringe a chamada a endereços que são governadores
    modifier onlyGovernador() {
        require(governadores[msg.sender], "Apenas governanca");
        _;
    }

    /// @notice Inicializa a governança apontando para o VetNFT
    /// @dev O deployer vira owner e já é registrado como primeiro governador.
    /// @param _vetNFT endereço do contrato VetNFT
    constructor(address _vetNFT) {
        require(_vetNFT != address(0), "VetNFT invalido");

        owner = msg.sender;
        vetNFT = VetNFT(_vetNFT);

        governadores[msg.sender] = true;
    }

    /// @notice Adiciona um novo governador (com direito a voto)
    /// @param governador endereço a ser autorizado
    function addGovernador(address governador) external onlyOwner {
        require(governador != address(0), "Endereco invalido");
        governadores[governador] = true;
    }

    /// @notice Remove um governador
    /// @dev O owner não pode ser removido como governador.
    /// @param governador endereço a ser removido
    function removeGovernador(address governador) external onlyOwner {
        require(governador != owner, "Owner nao pode sair");
        governadores[governador] = false;
    }

    /// @notice Cria uma solicitação de cadastro de vet a ser votada pela governança
    /// @dev Reverte se o solicitante já possui NFT no VetNFT. Define o deadline como
    ///      agora + votingPeriod.
    /// @param nome     nome do veterinário
    /// @param crmv     registro profissional (CRMV)
    /// @param cidade   cidade de atuação
    /// @param bairro   bairro de atuação
    /// @param telefone telefone de contato
    function solicitarCadastro(
        string calldata nome,
        string calldata crmv,
        string calldata cidade,
        string calldata bairro,
        string calldata telefone
    ) external {
        require(bytes(nome).length > 0, "Nome invalido");
        require(bytes(crmv).length > 0, "CRMV invalido");
        require(bytes(cidade).length > 0, "Cidade invalida");
        require(bytes(bairro).length > 0, "Bairro invalido");
        require(bytes(telefone).length > 0, "Telefone invalido");
        require(!vetNFT.hasNFT(msg.sender), "Vet ja possui NFT");

        requestCounter++;

        requests[requestCounter] = VetRequest({
            vet: msg.sender,
            nome: nome,
            crmv: crmv,
            cidade: cidade,
            bairro: bairro,
            telefone: telefone,
            votosSim: 0,
            votosNao: 0,
            deadline: block.timestamp + votingPeriod,
            status: Status.PENDENTE,
            exists: true
        });

        emit VetSolicitou(requestCounter, msg.sender, nome, crmv, cidade, bairro, telefone);
    }

    /// @notice Registra o voto de um governador em uma solicitação pendente
    /// @dev Cada governador só vota uma vez por solicitação, e apenas dentro do prazo.
    /// @param requestId id da solicitação
    /// @param aprovar   true para voto a favor, false para contra
    function votar(uint256 requestId, bool aprovar) external onlyGovernador {
        VetRequest storage request = requests[requestId];

        require(request.exists, "Solicitacao inexistente");
        require(request.status == Status.PENDENTE, "Votacao encerrada");
        require(block.timestamp <= request.deadline, "Prazo encerrado");
        require(!jaVotou[requestId][msg.sender], "Ja votou");

        // Marca como votado antes de contar (evita voto duplo)
        jaVotou[requestId][msg.sender] = true;

        if (aprovar) {
            request.votosSim++;
        } else {
            request.votosNao++;
        }

        emit VotoRegistrado(requestId, msg.sender, aprovar);
    }

    /// @notice Finaliza a votação após o prazo e aprova ou rejeita a solicitação
    /// @dev Qualquer um pode chamar (não tem modifier), mas só funciona após o deadline.
    ///      Aprova se atingir o quorum mínimo E tiver mais votos sim do que não; nesse
    ///      caso chama vetNFT.registerVetByGovernance para mintar o NFT. Caso contrário,
    ///      marca como REJEITADO.
    /// @param requestId id da solicitação a finalizar
    function finalizarVotacao(uint256 requestId) external {
        VetRequest storage request = requests[requestId];

        require(request.exists, "Solicitacao inexistente");
        require(request.status == Status.PENDENTE, "Ja finalizada");
        require(block.timestamp > request.deadline, "Votacao ainda aberta");

        uint256 totalVotos = request.votosSim + request.votosNao;

        // Aprovação exige quorum mínimo E maioria a favor
        if (
            totalVotos >= quorumMinimo &&
            request.votosSim > request.votosNao
        ) {
            request.status = Status.APROVADO;

            // Minta o NFT no VetNFT (este contrato precisa ser a governance lá)
            vetNFT.registerVetByGovernance(
                request.vet,
                request.nome,
                request.crmv,
                request.cidade,
                request.bairro,
                request.telefone
            );

            emit VetAprovado(requestId, request.vet);
        } else {
            request.status = Status.REJEITADO;

            emit VetRejeitado(requestId, request.vet);
        }
    }

    /// @notice Altera a duração padrão da janela de votação
    /// @param novoPeriodo novo período em segundos (mínimo 1 hora)
    function setVotingPeriod(uint256 novoPeriodo) external onlyOwner {
        require(novoPeriodo >= 1 hours, "Periodo muito curto");
        votingPeriod = novoPeriodo;
    }

    /// @notice Altera o quorum mínimo de votos para validar uma votação
    /// @param novoQuorum novo quorum (deve ser > 0)
    function setQuorumMinimo(uint256 novoQuorum) external onlyOwner {
        require(novoQuorum > 0, "Quorum invalido");
        quorumMinimo = novoQuorum;
    }
}
