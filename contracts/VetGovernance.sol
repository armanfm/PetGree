// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VetNFT.sol";

/// @title VetGovernance — Governança simples para aprovar ou rejeitar veterinários
/// @notice Veterinário solicita cadastro, governança vota e, se aprovado, NFT é mintado
contract VetGovernance {

    enum Status {
        PENDENTE,
        APROVADO,
        REJEITADO
    }

    struct VetRequest {
        address vet;
        string nome;
        string crmv;
        string cidade;
        string bairro;
        string telefone;
        uint256 votosSim;
        uint256 votosNao;
        uint256 deadline;
        Status status;
        bool exists;
    }

    VetNFT public vetNFT;

    uint256 public requestCounter;
    uint256 public votingPeriod = 3 days;
    uint256 public quorumMinimo = 1;

    mapping(uint256 => VetRequest) public requests;
    mapping(uint256 => mapping(address => bool)) public jaVotou;
    mapping(address => bool) public governadores;

    address public owner;

    event VetSolicitou(
        uint256 indexed requestId,
        address indexed vet,
        string nome,
        string crmv,
        string cidade,
        string bairro,
        string telefone
    );

    event VotoRegistrado(
        uint256 indexed requestId,
        address indexed voter,
        bool aprovado
    );

    event VetAprovado(
        uint256 indexed requestId,
        address indexed vet
    );

    event VetRejeitado(
        uint256 indexed requestId,
        address indexed vet
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Apenas owner");
        _;
    }

    modifier onlyGovernador() {
        require(governadores[msg.sender], "Apenas governanca");
        _;
    }

    constructor(address _vetNFT) {
        require(_vetNFT != address(0), "VetNFT invalido");

        owner = msg.sender;
        vetNFT = VetNFT(_vetNFT);

        governadores[msg.sender] = true;
    }

    function addGovernador(address governador) external onlyOwner {
        require(governador != address(0), "Endereco invalido");
        governadores[governador] = true;
    }

    function removeGovernador(address governador) external onlyOwner {
        require(governador != owner, "Owner nao pode sair");
        governadores[governador] = false;
    }

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

    function votar(uint256 requestId, bool aprovar) external onlyGovernador {
        VetRequest storage request = requests[requestId];

        require(request.exists, "Solicitacao inexistente");
        require(request.status == Status.PENDENTE, "Votacao encerrada");
        require(block.timestamp <= request.deadline, "Prazo encerrado");
        require(!jaVotou[requestId][msg.sender], "Ja votou");

        jaVotou[requestId][msg.sender] = true;

        if (aprovar) {
            request.votosSim++;
        } else {
            request.votosNao++;
        }

        emit VotoRegistrado(requestId, msg.sender, aprovar);
    }

    function finalizarVotacao(uint256 requestId) external {
        VetRequest storage request = requests[requestId];

        require(request.exists, "Solicitacao inexistente");
        require(request.status == Status.PENDENTE, "Ja finalizada");
        require(block.timestamp > request.deadline, "Votacao ainda aberta");

        uint256 totalVotos = request.votosSim + request.votosNao;

        if (
            totalVotos >= quorumMinimo &&
            request.votosSim > request.votosNao
        ) {
            request.status = Status.APROVADO;

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

    function setVotingPeriod(uint256 novoPeriodo) external onlyOwner {
        require(novoPeriodo >= 1 hours, "Periodo muito curto");
        votingPeriod = novoPeriodo;
    }

    function setQuorumMinimo(uint256 novoQuorum) external onlyOwner {
        require(novoQuorum > 0, "Quorum invalido");
        quorumMinimo = novoQuorum;
    }
}
