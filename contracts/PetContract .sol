// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VetNFT.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title PetContract - Prontuario descentralizado de um pet
/// @notice Cada pet tem seu proprio contrato deployado pelo PetFactory
/// @dev Historico imutavel: consultas, vacinas, atestados e memorial
///      Pagamento e presencial - o contrato registra apenas o prontuario
contract PetContract {

    // ENUMS

    enum TipoConsulta  { CONSULTA, VACINACAO, INTERNACAO, CIRURGIA, OUTROS }
    enum StatusConsulta { ABERTA, FINALIZADA }

    // STRUCTS

    struct Consulta {
        uint256        id;
        TipoConsulta   tipo;
        address        vet;
        string         registroPublico;
        uint256        preco;
        uint256        diasInternacao;
        uint256        data;
        StatusConsulta status;
    }

    struct Atestado {
        address vet;
        string  conteudo;
        uint256 data;
    }

    struct Memorial {
        string  historia;
        uint256 dataObito;
        uint256 dataRegistro;
    }

    // DADOS DO PET

    string  public nome;
    string  public raca;
    address public dono;
    uint256 public dataNascimento;
    address public pai;
    address public mae;
    bool    public falecido;

    Memorial public memorial;

    // HISTORICO

    Consulta[] public consultas;
    Atestado[] public atestados;

    uint256 private _consultaCounter;

    // REFERENCIAS EXTERNAS

    VetNFT public vetNFT;

    // CHAINLINK

    AggregatorV3Interface public ethUsdFeed;
    AggregatorV3Interface public brlUsdFeed;

    // EVENTS

    event ConsultaAberta(uint256 indexed id, address indexed vet, TipoConsulta tipo, uint256 preco);
    event RegistroPublicoAdicionado(uint256 indexed id, address indexed vet, string registroPublico);
    event ConsultaFinalizada(uint256 indexed id, address indexed vet);
    event AtestadoEmitido(address indexed vet, uint256 data);
    event PetFalecido(string historia, uint256 dataObito);

    // MODIFIERS

    modifier apenasDono() {
        require(msg.sender == dono, "Apenas o dono");
        _;
    }

    modifier apenasVetAtivo() {
        require(vetNFT.isVetActive(msg.sender), "Apenas vets com NFT ativo");
        _;
    }

    modifier petVivo() {
        require(!falecido, "Pet falecido: historico encerrado");
        _;
    }

    // CONSTRUCTOR

    constructor(
        string  memory _nome,
        string  memory _raca,
        address        _dono,
        uint256        _dataNascimento,
        address        _pai,
        address        _mae,
        address        _vetNFT,
        address        _ethUsdFeed,
        address        _brlUsdFeed
    ) {
        nome           = _nome;
        raca           = _raca;
        dono           = _dono;
        dataNascimento = _dataNascimento;
        pai            = _pai;
        mae            = _mae;
        vetNFT         = VetNFT(_vetNFT);
        ethUsdFeed     = AggregatorV3Interface(_ethUsdFeed);

        if (_brlUsdFeed != address(0)) {
            brlUsdFeed = AggregatorV3Interface(_brlUsdFeed);
        }
    }

    // CONSULTA

    function openConsultation(
        address      vetAddress,
        TipoConsulta tipo,
        uint256      diasInternacao
    ) external apenasDono petVivo {
        require(vetNFT.isVetActive(vetAddress), "Vet invalido ou inativo");
        require(
            tipo != TipoConsulta.INTERNACAO || diasInternacao > 0,
            "Informe as diarias"
        );
        require(
            tipo == TipoConsulta.INTERNACAO || diasInternacao == 0,
            "Diarias apenas internacao"
        );

        uint256 preco = vetNFT.getVetPrice(vetAddress, uint8(tipo), diasInternacao);

        _consultaCounter++;
        uint256 id = _consultaCounter;

        consultas.push(Consulta({
            id:              id,
            tipo:            tipo,
            vet:             vetAddress,
            registroPublico: "",
            preco:           preco,
            diasInternacao:  diasInternacao,
            data:            block.timestamp,
            status:          StatusConsulta.ABERTA
        }));

        emit ConsultaAberta(id, vetAddress, tipo, preco);
    }

    function addRecord(
        uint256         consultaId,
        string calldata conteudo
    ) external apenasVetAtivo petVivo {
        Consulta storage consulta = _getConsulta(consultaId);

        require(consulta.vet == msg.sender,               "Nao e o vet desta consulta");
        require(consulta.status == StatusConsulta.ABERTA, "Consulta nao esta aberta");
        require(consulta.tipo == TipoConsulta.VACINACAO,  "Registro publico apenas vacina");
        require(bytes(conteudo).length > 0,               "Conteudo vazio");

        consulta.registroPublico = conteudo;

        emit RegistroPublicoAdicionado(consultaId, msg.sender, conteudo);
    }

    function finalizeConsultation(uint256 consultaId) external apenasVetAtivo petVivo {
        Consulta storage consulta = _getConsulta(consultaId);

        require(consulta.vet == msg.sender,               "Nao e o vet desta consulta");
        require(consulta.status == StatusConsulta.ABERTA, "Consulta nao esta aberta");
        require(
            consulta.tipo != TipoConsulta.VACINACAO ||
            bytes(consulta.registroPublico).length > 0,
            "Adicione a vacina antes de finalizar"
        );

        consulta.status = StatusConsulta.FINALIZADA;

        emit ConsultaFinalizada(consultaId, msg.sender);
    }

    // ATESTADO DIGITAL

    function issueAtestado(string calldata conteudo) external apenasVetAtivo petVivo {
        require(bytes(conteudo).length > 0, "Conteudo vazio");

        atestados.push(Atestado({
            vet:      msg.sender,
            conteudo: conteudo,
            data:     block.timestamp
        }));

        emit AtestadoEmitido(msg.sender, block.timestamp);
    }

    // MEMORIAL

    function markAsDeceased(
        string calldata historia,
        uint256         dataObito
    ) external apenasDono petVivo {
        require(bytes(historia).length > 0, "Escreva a historia do pet");
        require(dataObito <= block.timestamp, "Data de obito invalida");
        require(_temVacinacaoRegistrada(), "Memorial exige vacinacao registrada");

        falecido = true;

        memorial = Memorial({
            historia:     historia,
            dataObito:    dataObito,
            dataRegistro: block.timestamp
        });

        emit PetFalecido(historia, dataObito);
    }

    // CHAINLINK

    function converterParaReais(uint256 weiAmount)
        external
        view
        returns (uint256 reais, uint256 centavos)
    {
        require(
            address(ethUsdFeed) != address(0) && address(brlUsdFeed) != address(0),
            "Feeds de preco nao configurados"
        );

        (, int256 ethUsd, , , ) = ethUsdFeed.latestRoundData();
        (, int256 brlUsd, , , ) = brlUsdFeed.latestRoundData();

        require(ethUsd > 0 && brlUsd > 0, "Preco invalido no feed");

        uint256 totalCentavos = (weiAmount * uint256(ethUsd) * 100) / (1e18 * uint256(brlUsd));

        reais    = totalCentavos / 100;
        centavos = totalCentavos % 100;
    }

    function getPrecoConsultaEmReais(uint256 consultaId)
        external
        view
        returns (uint256 reais, uint256 centavos)
    {
        Consulta storage c = _getConsulta(consultaId);
        return this.converterParaReais(c.preco);
    }

    // VIEWS

    function getConsultas() external view returns (Consulta[] memory) {
        return consultas;
    }

    function getAtestados() external view returns (Atestado[] memory) {
        return atestados;
    }

    function getMemorial() external view returns (Memorial memory) {
        return memorial;
    }

    function totalConsultas() external view returns (uint256) {
        return consultas.length;
    }

    // INTERNAL

    function _getConsulta(uint256 consultaId) internal view returns (Consulta storage) {
        require(consultaId > 0 && consultaId <= consultas.length, "Consulta nao existe");
        return consultas[consultaId - 1];
    }

    function _temVacinacaoRegistrada() internal view returns (bool) {
        for (uint256 i = 0; i < consultas.length; i++) {
            if (
                consultas[i].tipo == TipoConsulta.VACINACAO &&
                bytes(consultas[i].registroPublico).length > 0
            ) {
                return true;
            }
        }

        return false;
    }
}
