// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VetNFT - Credencial NFT Soulbound para veterinarios
/// @notice Aprovacao manual via governanca/admin
contract VetNFT is ERC721, Ownable {

    // STRUCTS

    struct Vet {
        string nome;
        string crmv;
        string cidade;
        string bairro;
        string telefone;
        uint256 consultaPrice;
        uint256 diariaInternacaoPrice;
        bool ativo;
        uint256 tokenId;
    }

    // STATE

    uint256 private _tokenIdCounter;
    address public governance;

    mapping(address => Vet) public vets;
    mapping(address => bool) public hasNFT;
    address[] private _vetList;

    // EVENTS

    event VetSolicitado(address indexed vet, string crmv, string cidade, string bairro, string telefone);
    event VetRegistrado(address indexed vet, string crmv, string cidade, string bairro, string telefone, uint256 tokenId);
    event VetInativado(address indexed vet);
    event PrecoAtualizado(address indexed vet, uint256 novoPreco);
    event TelefoneAtualizado(address indexed vet, string novoTelefone);
    event GovernanceAtualizada(address indexed governance);

    // CONSTRUCTOR

    constructor()
        ERC721("PetgreeChain Vet", "PGVET")
        Ownable(msg.sender)
    {}

    modifier onlyOwnerOrGovernance() {
        require(
            msg.sender == owner() || msg.sender == governance,
            "Apenas owner ou governanca"
        );
        _;
    }

    // SOULBOUND

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);

        require(
            from == address(0),
            "VetNFT: soulbound, nao transferivel"
        );

        return super._update(to, tokenId, auth);
    }

    // REGISTRO

    function registerVet(
        string calldata nome,
        string calldata crmv,
        string calldata cidade,
        string calldata bairro,
        string calldata telefone
    ) external {
        require(!hasNFT[msg.sender], "Vet ja registrado");
        require(bytes(nome).length > 0, "Nome invalido");
        require(bytes(crmv).length > 0, "CRMV invalido");
        require(bytes(cidade).length > 0, "Cidade invalida");
        require(bytes(bairro).length > 0, "Bairro invalido");
        require(bytes(telefone).length > 0, "Telefone invalido");

        vets[msg.sender] = Vet({
            nome: nome,
            crmv: crmv,
            cidade: cidade,
            bairro: bairro,
            telefone: telefone,
            consultaPrice: 0,
            diariaInternacaoPrice: 0,
            ativo: false,
            tokenId: 0
        });

        emit VetSolicitado(msg.sender, crmv, cidade, bairro, telefone);
    }

    // GOVERNANCA / ADMIN

    function approveVet(address vetAddress) external onlyOwner {
        require(!hasNFT[vetAddress], "Ja aprovado");
        require(bytes(vets[vetAddress].nome).length > 0, "Vet inexistente");

        _mintVet(vetAddress);
    }

    function registerVetByGovernance(
        address vetAddress,
        string calldata nome,
        string calldata crmv,
        string calldata cidade,
        string calldata bairro,
        string calldata telefone
    ) external onlyOwnerOrGovernance {
        require(vetAddress != address(0), "Endereco invalido");
        require(!hasNFT[vetAddress], "Ja aprovado");
        require(bytes(nome).length > 0, "Nome invalido");
        require(bytes(crmv).length > 0, "CRMV invalido");
        require(bytes(cidade).length > 0, "Cidade invalida");
        require(bytes(bairro).length > 0, "Bairro invalido");
        require(bytes(telefone).length > 0, "Telefone invalido");

        vets[vetAddress].nome = nome;
        vets[vetAddress].crmv = crmv;
        vets[vetAddress].cidade = cidade;
        vets[vetAddress].bairro = bairro;
        vets[vetAddress].telefone = telefone;

        _mintVet(vetAddress);
    }

    function updateLocalidade(
        string calldata cidade,
        string calldata bairro,
        string calldata telefone
    ) external {
        require(hasNFT[msg.sender], "Vet inexistente");
        require(bytes(cidade).length > 0, "Cidade invalida");
        require(bytes(bairro).length > 0, "Bairro invalido");
        require(bytes(telefone).length > 0, "Telefone invalido");

        vets[msg.sender].cidade = cidade;
        vets[msg.sender].bairro = bairro;
        vets[msg.sender].telefone = telefone;

        emit TelefoneAtualizado(msg.sender, telefone);
    }

    function atualizarTelefone(string calldata novoTelefone) external {
        require(hasNFT[msg.sender], "Vet inexistente");
        require(bytes(novoTelefone).length > 0, "Telefone invalido");

        vets[msg.sender].telefone = novoTelefone;

        emit TelefoneAtualizado(msg.sender, novoTelefone);
    }

    function setGovernance(address governanceAddress) external onlyOwner {
        require(governanceAddress != address(0), "Endereco invalido");
        governance = governanceAddress;

        emit GovernanceAtualizada(governanceAddress);
    }

    function deactivateVet(address vetAddress)
        external
        onlyOwner
    {
        require(hasNFT[vetAddress], "Vet inexistente");

        vets[vetAddress].ativo = false;

        emit VetInativado(vetAddress);
    }

    // PRECO

    function setPrices(
        uint256 consultaPrice,
        uint256 diariaInternacaoPrice
    ) external {
        require(
            hasNFT[msg.sender] &&
            vets[msg.sender].ativo,
            "Apenas vets ativos"
        );

        vets[msg.sender].consultaPrice = consultaPrice;
        vets[msg.sender].diariaInternacaoPrice = diariaInternacaoPrice;

        emit PrecoAtualizado(msg.sender, consultaPrice);
    }

    // VIEWS

    function isVetActive(address vetAddress)
        external
        view
        returns (bool)
    {
        return hasNFT[vetAddress] &&
               vets[vetAddress].ativo;
    }

    function getVetPrice(
        address vetAddress,
        uint8 tipo,
        uint256 diasInternacao
    )
        external
        view
        returns (uint256)
    {
        Vet memory vet = vets[vetAddress];

        if (tipo == 0 || tipo == 1 || tipo == 3 || tipo == 4) {
            return vet.consultaPrice;
        }
        if (tipo == 2) return vet.diariaInternacaoPrice * diasInternacao;

        revert("Tipo invalido");
    }

    function getVet(address vetAddress)
        external
        view
        returns (Vet memory)
    {
        return vets[vetAddress];
    }

    function getAllVets() external view returns (address[] memory) {
        return _vetList;
    }

    function _mintVet(address vetAddress) internal {
        _tokenIdCounter++;

        uint256 tokenId = _tokenIdCounter;

        _safeMint(vetAddress, tokenId);

        vets[vetAddress].ativo = true;
        vets[vetAddress].tokenId = tokenId;

        hasNFT[vetAddress] = true;
        _vetList.push(vetAddress);

        emit VetRegistrado(
            vetAddress,
            vets[vetAddress].crmv,
            vets[vetAddress].cidade,
            vets[vetAddress].bairro,
            vets[vetAddress].telefone,
            tokenId
        );
    }
}
