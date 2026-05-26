// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PetContract.sol";

/// @title PetFactory — Registra pets e deploya um PetContract por pet
/// @notice Cada pet recebe seu próprio endereço de contrato na blockchain
/// @dev Pai e mãe são validados: só aceita endereços de PetContracts
///      registrados por esta própria factory
contract PetFactory {

    // ─────────────────────────────────────────────
    //  STRUCTS
    // ─────────────────────────────────────────────

    struct PetInfo {
        address contractAddress;
        string  nome;
        string  raca;
        address dono;
        uint256 dataRegistro;
    }

    // ─────────────────────────────────────────────
    //  STATE
    // ─────────────────────────────────────────────

    address public vetNFT;
    address public ethUsdFeed;
    address public brlUsdFeed;

    PetInfo[] public pets;

    mapping(address => address[]) public petsByOwner; // dono => contratos dos pets

    /// @notice Permite verificar se um endereço é um PetContract legítimo desta factory
    ///         Usado para validar pedigree (pai e mãe)
    mapping(address => bool) public isPetContract;

    // ─────────────────────────────────────────────
    //  EVENTS
    // ─────────────────────────────────────────────

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
    function getPetsByOwner(address owner) external view returns (address[] memory) {
        return petsByOwner[owner];
    }

    /// @notice Retorna o índice global com todos os pets registrados
    function getAllPets() external view returns (PetInfo[] memory) {
        return pets;
    }

    /// @notice Total de pets registrados na plataforma
    function totalPets() external view returns (uint256) {
        return pets.length;
    }

    /// @notice Confirma se um endereço é um PetContract legítimo desta factory
    function isPetRegistered(address petAddress) external view returns (bool) {
        return isPetContract[petAddress];
    }
}

