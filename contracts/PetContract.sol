// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VetNFT.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title PetContract - Prontuario descentralizado de um pet
/// @notice Cada pet tem seu proprio contrato deployado pelo PetFactory
/// @dev Historico imutavel: consultas, vacinas, atestados e memorial
///      Pagamento e presencial - o contrato registra apenas o prontuario.
///      Os feeds Chainlink sao usados apenas para converter precos (wei) em reais.
contract PetContract {
 VetNFT public vetNFT;
    // ENUMS

    /// @notice Tipos de atendimento que um vet pode registrar
    /// @dev A ordem importa: o indice numerico (0..4) e usado em VetNFT.getVetPrice.
    enum TipoConsulta  { CONSULTA, VACINACAO, INTERNACAO, CIRURGIA, OUTROS }
    /// @notice Estado de uma consulta no prontuario
    enum StatusConsulta { ABERTA, FINALIZADA }

    // STRUCTS

    /// @notice Registro de um atendimento no prontuario do pet
    struct Consulta {
        uint256        id;               // id sequencial da consulta (comeca em 1)
        TipoConsulta   tipo;             // tipo de atendimento
        address        vet;             // vet responsavel pelo atendimento
        string         registroPublico; // dado publico (ex: lote da vacina); so usado em vacinacao
        uint256        preco;           // preco cobrado, em wei (calculado no momento da abertura)
        uint256        diasInternacao;  // numero de diarias (apenas internacao)
        uint256        data;            // timestamp de abertura
        StatusConsulta status;          // ABERTA ou FINALIZADA
    }

    /// @notice Atestado digital emitido por um vet
    struct Atestado {
        address vet;       // vet que emitiu
        string  conteudo;  // texto do atestado
        uint256 data;      // timestamp de emissao
    }

    /// @notice Memorial do pet (preenchido apenas no falecimento)
    struct Memorial {
        string  historia;     // historia/homenagem ao pet
        uint256 dataObito;    // data do obito informada pelo dono
        uint256 dataRegistro; // timestamp em que o memorial foi registrado on-chain
    }

 // DADOS DO PET

/// @notice Nome do pet
string  public nome;
/// @notice Raca do pet
string  public raca;
/// @notice Endereco do tutor/dono
address public dono;
/// @notice Timestamp do nascimento
uint256 public dataNascimento;
/// @notice Endereco do PetContract do pai (address(0) se nao houver pedigree)
address public pai;
/// @notice Endereco do PetContract da mae (address(0) se nao houver pedigree)
address public mae;
/// @notice Indica se o pet faleceu; quando true, o historico fica encerrado
bool    public falecido;
/// @notice Dados do memorial, preenchidos no falecimento
Memorial public memorial;

// HISTORICO

/// @notice Historico de consultas do pet
Consulta[] public consultas;
/// @notice Historico de atestados do pet
Atestado[] public atestados;

uint256 private _consultaCounter; // contador incremental dos ids de consulta

// CHAINLINK

/// @notice Feed Chainlink de preco ETH/USD
AggregatorV3Interface public ethUsdFeed;
/// @notice Feed Chainlink de preco BRL/USD (opcional em redes de teste)
AggregatorV3Interface public brlUsdFeed;

    // EVENTS

    /// @notice Emitido ao abrir uma nova consulta
    event ConsultaAberta(uint256 indexed id, address indexed vet, TipoConsulta tipo, uint256 preco);
    /// @notice Emitido ao adicionar o registro publico (vacina) a uma consulta
    event RegistroPublicoAdicionado(uint256 indexed id, address indexed vet, string registroPublico);
    /// @notice Emitido ao finalizar uma consulta
    event ConsultaFinalizada(uint256 indexed id, address indexed vet);
    /// @notice Emitido ao emitir um atestado digital
    event AtestadoEmitido(address indexed vet, uint256 data);
    /// @notice Emitido quando o pet e marcado como falecido
    event PetFalecido(string historia, uint256 dataObito);

    // MODIFIERS

    /// @notice Restringe a chamada ao dono do pet
    modifier apenasDono() {
        require(msg.sender == dono, "Apenas o dono");
        _;
    }

    /// @notice Restringe a chamada a vets com NFT ativo (consultado no VetNFT)
    modifier apenasVetAtivo() {
        require(vetNFT.isVetActive(msg.sender), "Apenas vets com NFT ativo");
        _;
    }

    /// @notice Bloqueia operacoes apos o falecimento do pet
    modifier petVivo() {
        require(!falecido, "Pet falecido: historico encerrado");
        _;
    }

    // CONSTRUCTOR

    /// @notice Inicializa o prontuario do pet
    /// @dev Normalmente chamado pela PetFactory, nunca diretamente pelo usuario.
    ///      O feed BRL/USD e opcional: se address(0), a conversao para reais fica indisponivel.
    /// @param _nome           nome do pet
    /// @param _raca           raca do pet
    /// @param _dono           endereco do dono
    /// @param _dataNascimento timestamp de nascimento
    /// @param _pai            PetContract do pai (address(0) se nao houver)
    /// @param _mae            PetContract da mae (address(0) se nao houver)
    /// @param _vetNFT         endereco do contrato VetNFT
    /// @param _ethUsdFeed     endereco do feed Chainlink ETH/USD
    /// @param _brlUsdFeed     endereco do feed Chainlink BRL/USD (opcional)
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

        // Feed BRL/USD e opcional (pode nao existir em redes de teste)
        if (_brlUsdFeed != address(0)) {
            brlUsdFeed = AggregatorV3Interface(_brlUsdFeed);
        }
    }

    // CONSULTA

    /// @notice Abre uma nova consulta no prontuario, escolhendo o vet e o tipo
    /// @dev So o dono pode abrir, e apenas com o pet vivo. O preco e travado no momento
    ///      da abertura consultando VetNFT.getVetPrice. Diarias so sao validas (e exigidas)
    ///      para internacao.
    /// @param vetAddress     vet escolhido (precisa estar ativo no VetNFT)
    /// @param tipo           tipo de atendimento
    /// @param diasInternacao numero de diarias (>0 apenas se for internacao; 0 caso contrario)
    function openConsultation(
        address      vetAddress,
        TipoConsulta tipo,
        uint256      diasInternacao
    ) external apenasDono petVivo {
        require(vetNFT.isVetActive(vetAddress), "Vet invalido ou inativo");
        // Internacao exige pelo menos 1 diaria
        require(
            tipo != TipoConsulta.INTERNACAO || diasInternacao > 0,
            "Informe as diarias"
        );
        // Tipos que nao sao internacao nao podem ter diarias
        require(
            tipo == TipoConsulta.INTERNACAO || diasInternacao == 0,
            "Diarias apenas internacao"
        );

        // Trava o preco no momento da abertura
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

    /// @notice Adiciona o registro publico de uma vacinacao a uma consulta aberta
    /// @dev So o vet responsavel pela consulta pode chamar, e apenas em consultas do
    ///      tipo VACINACAO que ainda estejam abertas. Esse registro e exigido antes de
    ///      finalizar a vacinacao e para habilitar o memorial.
    /// @param consultaId id da consulta
    /// @param conteudo   dado publico (ex: lote/fabricante da vacina)
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

    /// @notice Finaliza uma consulta aberta
    /// @dev So o vet responsavel pode finalizar. Se for vacinacao, exige que o registro
    ///      publico ja tenha sido adicionado (via addRecord) antes de finalizar.
    /// @param consultaId id da consulta a finalizar
    function finalizeConsultation(uint256 consultaId) external apenasVetAtivo petVivo {
        Consulta storage consulta = _getConsulta(consultaId);

        require(consulta.vet == msg.sender,               "Nao e o vet desta consulta");
        require(consulta.status == StatusConsulta.ABERTA, "Consulta nao esta aberta");
        // Vacinacao so finaliza com o registro publico ja preenchido
        require(
            consulta.tipo != TipoConsulta.VACINACAO ||
            bytes(consulta.registroPublico).length > 0,
            "Adicione a vacina antes de finalizar"
        );

        consulta.status = StatusConsulta.FINALIZADA;

        emit ConsultaFinalizada(consultaId, msg.sender);
    }

    // ATESTADO DIGITAL

    /// @notice Emite um atestado digital para o pet
    /// @dev Qualquer vet ativo pode emitir, com o pet vivo. Fica registrado no historico.
    /// @param conteudo texto do atestado
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

    /// @notice Marca o pet como falecido e registra o memorial (encerra o historico)
    /// @dev So o dono pode chamar, e apenas com o pet ainda vivo. Exige que exista ao
    ///      menos uma vacinacao com registro publico. Apos isso, todas as funcoes com
    ///      o modifier petVivo ficam bloqueadas.
    /// @param historia  historia/homenagem ao pet
    /// @param dataObito data do obito (nao pode ser no futuro)
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

    /// @notice Converte um valor em wei (ETH) para reais usando os feeds Chainlink
    /// @dev Combina ETH/USD e BRL/USD para obter o valor em BRL. Reverte se os feeds
    ///      nao estiverem configurados ou retornarem preco invalido.
    /// @param weiAmount valor em wei a converter
    /// @return reais    parte inteira em reais
    /// @return centavos parte fracionaria em centavos (0..99)
    function converterParaReais(uint256 weiAmount)
        external
        view
        returns (uint256 reais, uint256 centavos)
    {
        require(
            address(ethUsdFeed) != address(0) && address(brlUsdFeed) != address(0),
            "Feeds de preco nao configurados"
        );

        // Le os precos mais recentes de cada feed (ignora os demais campos do round)
        (, int256 ethUsd, , , ) = ethUsdFeed.latestRoundData();
        (, int256 brlUsd, , , ) = brlUsdFeed.latestRoundData();

        require(ethUsd > 0 && brlUsd > 0, "Preco invalido no feed");

        // wei -> centavos de BRL: (wei * USD/ETH * 100) / (1e18 * USD/BRL)
        uint256 totalCentavos = (weiAmount * uint256(ethUsd) * 100) / (1e18 * uint256(brlUsd));

        reais    = totalCentavos / 100;
        centavos = totalCentavos % 100;
    }

    /// @notice Retorna o preco de uma consulta convertido para reais
    /// @dev Atalho que le o preco travado da consulta e usa converterParaReais.
    /// @param consultaId id da consulta
    /// @return reais    parte inteira em reais
    /// @return centavos parte fracionaria em centavos
    function getPrecoConsultaEmReais(uint256 consultaId)
        external
        view
        returns (uint256 reais, uint256 centavos)
    {
        Consulta storage c = _getConsulta(consultaId);
        return this.converterParaReais(c.preco);
    }

    // VIEWS

    /// @notice Retorna o historico completo de consultas
    function getConsultas() external view returns (Consulta[] memory) {
        return consultas;
    }

    /// @notice Retorna o historico completo de atestados
    function getAtestados() external view returns (Atestado[] memory) {
        return atestados;
    }

    /// @notice Retorna o memorial do pet
    function getMemorial() external view returns (Memorial memory) {
        return memorial;
    }

    /// @notice Retorna o numero total de consultas registradas
    function totalConsultas() external view returns (uint256) {
        return consultas.length;
    }

    // INTERNAL

    /// @notice Busca uma consulta pelo id, validando os limites
    /// @dev Ids comecam em 1; o array e indexado em 0, por isso o `consultaId - 1`.
    /// @param consultaId id da consulta (1..length)
    /// @return referencia storage para a consulta
    function _getConsulta(uint256 consultaId) internal view returns (Consulta storage) {
        require(consultaId > 0 && consultaId <= consultas.length, "Consulta nao existe");
        return consultas[consultaId - 1];
    }

    /// @notice Verifica se existe ao menos uma vacinacao com registro publico
    /// @dev Percorre todo o historico; custo cresce com o numero de consultas.
    /// @return true se houver vacinacao registrada
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
