// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PetContract.sol";

/// @title PetFactory — Registra pets e deploya um PetContract por pet
/// @notice Cada pet recebe seu próprio endereço de contrato na blockchain
/// @dev Pai e mãe são validados: só aceita endereços de PetContracts
///      registrados por esta própria factory. A factory guarda as referências
///      compartilhadas (VetNFT e feeds Chainlink) e as injeta em cada PetContract.
contract PetFactory {

    // ─────────────────────────────────────────────
    //  STRUCTS
    // ─────────────────────────────────────────────

    /// @notice Resumo de um pet registrado, usado no índice global
    struct PetInfo {
        address contractAddress; // endereço do PetContract deployado
        string  nome;            // nome do pet
        string  raca;            // raça do pet
        address dono;            // dono no momento do registro
        uint256 dataRegistro;    // timestamp do registro
    }

    // ─────────────────────────────────────────────
    //  STATE
    // ─────────────────────────────────────────────

    address public vetNFT;     // endereço do contrato VetNFT (injetado em cada pet)
    address public ethUsdFeed; // feed Chainlink ETH/USD (injetado em cada pet)
    address public brlUsdFeed; // feed Chainlink BRL/USD (injetado em cada pet; pode ser 0)

    PetInfo[] public pets;     // índice global de todos os pets registrados

    mapping(address => address[]) public petsByOwner; // dono => contratos dos pets

    /// @notice Permite verificar se um endereço é um PetContract legítimo desta factory
    ///         Usado para validar pedigree (pai e mãe)
    mapping(address => bool) public isPetContract;

    // ─────────────────────────────────────────────
    //  EVENTS
    // ─────────────────────────────────────────────

    /// @notice Emitido a cada novo pet registrado e deployado
    event PetRegistrado(
        address indexed dono,
        address indexed petContract,
        string  nome,
        string  raca,
        address pai,
        address mae
    );

    // ─────────────────────────────────────────────
    //  CONSTRUCTOR
    // ─────────────────────────────────────────────

    /// @notice Configura as referências compartilhadas usadas por todos os pets
    /// @param _vetNFT      Endereço do contrato VetNFT
    /// @param _ethUsdFeed  Chainlink ETH/USD (ex: Polygon 0xF9680D99D6C9589e2a93a78A04A279e509205945)
    /// @param _brlUsdFeed  Chainlink BRL/USD (ex: Polygon 0x4b7836916781CAAfbb7Bd1E5FDd20ED544B453b1)
    ///                     Passe address(0) em rede de teste se o feed não estiver disponível
    constructor(
        address _vetNFT,
        address _ethUsdFeed,
        address _brlUsdFeed
    ) {
        require(_vetNFT     != address(0), "VetNFT invalido");
        require(_ethUsdFeed != address(0), "Feed ETH/USD invalido");

        vetNFT     = _vetNFT;
        ethUsdFeed = _ethUsdFeed;
        brlUsdFeed = _brlUsdFeed; // pode ser address(0) em teste
    }

    // ─────────────────────────────────────────────
    //  REGISTRO DE PET
    // ─────────────────────────────────────────────

    /// @notice Deploya um novo PetContract e registra o pet no índice global
    /// @dev O dono é o msg.sender. Pai e mãe, se informados, precisam ser PetContracts
    ///      desta mesma factory (validação de pedigree). O novo contrato recebe as
    ///      referências compartilhadas (VetNFT e feeds) automaticamente.
    /// @param nome           Nome do pet
    /// @param raca           Raça do pet
    /// @param dataNascimento Timestamp do nascimento
    /// @param pai            Endereço do PetContract do pai (address(0) se não tiver)
    /// @param mae            Endereço do PetContract da mãe (address(0) se não tiver)
    /// @return petAddress    Endereço do contrato recém-deployado
    function registerPet(
        string  calldata nome,
        string  calldata raca,
        uint256          dataNascimento,
        address          pai,
        address          mae
    ) external returns (address petAddress) {
        require(bytes(nome).length > 0, "Nome invalido");
        require(bytes(raca).length > 0, "Raca invalida");

        // ── Validação de pedigree ──────────────────────────────────────────
        // Só aceita endereços de PetContracts deployados por esta factory.
        // address(0) é permitido para indicar "sem pedigree conhecido".
        require(
            pai == address(0) || isPetContract[pai],
            "Pai invalido: nao e um PetContract registrado nesta factory"
        );
        require(
            mae == address(0) || isPetContract[mae],
            "Mae invalida: nao e um PetContract registrado nesta factory"
        );

        // ── Deploy ────────────────────────────────────────────────────────
        // Cria o contrato do pet injetando as referências compartilhadas da factory
        PetContract pet = new PetContract(
            nome,
            raca,
            msg.sender,
            dataNascimento,
            pai,
            mae,
            vetNFT,
            ethUsdFeed,
            brlUsdFeed
        );

        petAddress = address(pet);

        // Marca como PetContract oficial desta factory (usado para pedigree futuro)
        isPetContract[petAddress] = true;

        // Adiciona ao índice global e ao índice por dono
        pets.push(PetInfo({
            contractAddress: petAddress,
            nome:            nome,
            raca:            raca,
            dono:            msg.sender,
            dataRegistro:    block.timestamp
        }));

        petsByOwner[msg.sender].push(petAddress);

        emit PetRegistrado(msg.sender, petAddress, nome, raca, pai, mae);
    }

    // ─────────────────────────────────────────────
    //  VIEWS
    // ─────────────────────────────────────────────

    /// @notice Retorna todos os contratos de pets de um dono
    /// @param owner endereço do dono
    /// @return array com os endereços dos PetContracts do dono
    function getPetsByOwner(address owner) external view returns (address[] memory) {
        return petsByOwner[owner];
    }

    /// @notice Retorna o índice global com todos os pets registrados
    /// @dev O array cresce indefinidamente; pode ficar caro com muitos pets.
    /// @return array de PetInfo com todos os pets
    function getAllPets() external view returns (PetInfo[] memory) {
        return pets;
    }

    /// @notice Total de pets registrados na plataforma
    /// @return quantidade de pets
    function totalPets() external view returns (uint256) {
        return pets.length;
    }

    /// @notice Confirma se um endereço é um PetContract legítimo desta factory
    /// @param petAddress endereço a verificar
    /// @return true se foi deployado por esta factory
    function isPetRegistered(address petAddress) external view returns (bool) {
        return isPetContract[petAddress];
    }
}
