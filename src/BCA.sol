// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// BCA — BRICS Clearing Architecture (MVP)
// Protocolo: 2026 | Ano base PIB: 2025 | Sem mercado secundário
// Paper: "Arquitetura Monetária Elástica para o BRICS" (Manuscrito v40)

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UD60x18, ud, unwrap, exp, ln} from "@prb/math/src/UD60x18.sol";
import {SD59x18, sd, unwrap as unwrapSD} from "@prb/math/src/SD59x18.sol";

contract BCA is ERC20, Ownable {

    // ── Constantes do genesis ─────────────────────────────────────────────
    uint256 public constant GDP_BASE_YEAR     = 2025;
    uint256 public constant MINT_FRACTION_PCT = 50;
    uint256 public constant MAX_SHARE_PCT     = 50;
    uint256 public constant Y_0_BRL           = 12_700_000_000_000;

    // ── Parâmetros do mecanismo (imutáveis) ───────────────────────────────
    UD60x18 public immutable ALPHA;
    UD60x18 public immutable K;
    UD60x18 public immutable ALPHA_EMA;

    // ── Estado do mecanismo ───────────────────────────────────────────────
    UD60x18 public F;
    UD60x18 public P;
    UD60x18 public V;
    UD60x18 public V_prev;
    SD59x18 public g_hat;

    // ── Membros ───────────────────────────────────────────────────────────
    mapping(address => bytes32) public jurisdictionOf;
    address[] public members;
    address public governance;

    // ── Eventos ───────────────────────────────────────────────────────────
    event MemberAdmitted(address indexed member, bytes32 jurisdiction, uint256 mintAmount);
    event ClearingRecorded(address indexed from, address indexed to, uint256 amount);
    event FundamentalUpdated(uint256 newF);
    event PriceUpdated(uint256 newP);

    // ─────────────────────────────────────────────────────────────────────
    // TANH INTERNO — implementado via exp, sem dependência de versão
    // tanh(x) = (e^2x − 1) / (e^2x + 1)
    // Funciona para x positivo e negativo via simetria: tanh(-x) = -tanh(x)
    // ─────────────────────────────────────────────────────────────────────
    function _tanh(SD59x18 x) internal pure returns (SD59x18) {
        SD59x18 ONE = sd(1e18);
        SD59x18 TWO = sd(2e18);

        if (unwrapSD(x) == 0) return sd(0);

        if (unwrapSD(x) > 0) {
            // e^(2x)
            UD60x18 e2x   = exp(ud(uint256(unwrapSD(TWO.mul(x)))));
            SD59x18 e2x_s = sd(int256(unwrap(e2x)));
            // (e^2x - 1) / (e^2x + 1)
            return e2x_s.sub(ONE).div(e2x_s.add(ONE));
        } else {
            // tanh(-x) = -tanh(x)
            SD59x18 pos_x = sd(-unwrapSD(x));
            UD60x18 e2x   = exp(ud(uint256(unwrapSD(TWO.mul(pos_x)))));
            SD59x18 e2x_s = sd(int256(unwrap(e2x)));
            SD59x18 pos   = e2x_s.sub(ONE).div(e2x_s.add(ONE));
            return sd(-unwrapSD(pos));
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // GENESIS
    // ─────────────────────────────────────────────────────────────────────
    constructor(
        address brasilCB,
        uint256 alphaWei,
        uint256 kWei,
        uint256 alphaEmaWei
    ) ERC20("BRICS Clearing Architecture", "BCA") Ownable(msg.sender) {
        require(brasilCB    != address(0));
        require(alphaWei    > 0 && alphaWei    < 1e18);
        require(kWei        > 0 && kWei        < 1e18);
        require(alphaEmaWei > 0 && alphaEmaWei < 1e18);

        // 0 < α·k < 2 (Teorema 1 — condição de estabilidade)
        require((alphaWei * kWei) / 1e18 < 2e18);

        ALPHA     = ud(alphaWei);
        K         = ud(kWei);
        ALPHA_EMA = ud(alphaEmaWei);

        // Mint genesis: 50% do PIB Brasil 2025 = 6,35 trilhões de tokens
        uint256 mintGenesis = (Y_0_BRL * MINT_FRACTION_PCT / 100) * 1e18;
        _mint(brasilCB, mintGenesis);

        F      = ud(1e18);
        P      = ud(1e18);
        V      = ud(mintGenesis);
        V_prev = ud(mintGenesis);
        g_hat  = sd(0);

        jurisdictionOf[brasilCB] = "BR";
        members.push(brasilCB);
        governance = msg.sender;
    }

    // ─────────────────────────────────────────────────────────────────────
    // RESTRIÇÃO: tokens só circulam entre membros
    // ─────────────────────────────────────────────────────────────────────
    function _update(address from, address to, uint256 value) internal virtual override {
        if (from != address(0) && to != address(0)) {
            require(jurisdictionOf[from] != bytes32(0), "BCA: not member");
            require(jurisdictionOf[to]   != bytes32(0), "BCA: not member");
        }
        super._update(from, to, value);
    }

    // ─────────────────────────────────────────────────────────────────────
    // CLEARING — 2 jurisdições distintas obrigatório (anti-pirâmide)
    // ─────────────────────────────────────────────────────────────────────
    function recordClearing(address to, uint256 amount) external {
        require(jurisdictionOf[msg.sender] != bytes32(0), "BCA: not member");
        require(jurisdictionOf[to]         != bytes32(0), "BCA: not member");
        require(jurisdictionOf[msg.sender] != jurisdictionOf[to], "BCA: same jurisdiction");
        require(amount > 0);

        _transfer(msg.sender, to, amount);
        V_prev = V;
        V      = V.add(ud(amount));

        emit ClearingRecorded(msg.sender, to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    // FUNDAMENTAL F_t — Mini-PIB on-chain (Eqs. 5.1 e 5.2)
    // ─────────────────────────────────────────────────────────────────────
    function updateFundamental() external {
        require(unwrap(V_prev) > 0);

        SD59x18 g_t = sd(int256(unwrap(ln(V.div(V_prev)))));

        g_hat = sd(int256(unwrap(ALPHA_EMA))).mul(g_t)
                .add(sd(int256(1e18) - int256(unwrap(ALPHA_EMA))).mul(g_hat));

        if (unwrapSD(g_hat) >= 0) {
            F = F.mul(exp(ud(uint256(unwrapSD(g_hat)))));
        } else {
            F = F.div(exp(ud(uint256(-unwrapSD(g_hat)))));
        }

        emit FundamentalUpdated(unwrap(F));
    }

    // ─────────────────────────────────────────────────────────────────────
    // RECONVERGÊNCIA ELÁSTICA (Eq. 3.2)
    // P_{t+1} = P_t · [1 − α · tanh(k · (P/F − 1))]
    // ─────────────────────────────────────────────────────────────────────
    function applyReconvergence() external {
        SD59x18 P_s  = sd(int256(unwrap(P)));
        SD59x18 F_s  = sd(int256(unwrap(F)));
        SD59x18 dev  = P_s.div(F_s).sub(sd(1e18));
        SD59x18 mult = sd(1e18).sub(
                           sd(int256(unwrap(ALPHA))).mul(
                               _tanh(sd(int256(unwrap(K))).mul(dev))
                           )
                       );

        require(unwrapSD(mult) > 0);
        P = ud(uint256(unwrapSD(P_s.mul(mult))));

        emit PriceUpdated(unwrap(P));
    }

    // ─────────────────────────────────────────────────────────────────────
    // ADMISSÃO — mint 50% do PIB 2025 | teto 50% do supply
    // ─────────────────────────────────────────────────────────────────────
    function admitMember(address newMember, bytes32 jurisdiction, uint256 gdp2025)
        external
    {
        require(msg.sender == governance,                "BCA: not governance");
        require(newMember != address(0));
        require(jurisdiction != bytes32(0));
        require(gdp2025 > 0);
        require(jurisdictionOf[newMember] == bytes32(0), "BCA: already member");

        uint256 mintAmount  = (gdp2025 * MINT_FRACTION_PCT / 100) * 1e18;
        uint256 supplyAfter = totalSupply() + mintAmount;

        require(
            (mintAmount * 100) / supplyAfter < MAX_SHARE_PCT,
            "BCA: exceeds 50% of supply"
        );

        jurisdictionOf[newMember] = jurisdiction;
        members.push(newMember);
        _mint(newMember, mintAmount);

        emit MemberAdmitted(newMember, jurisdiction, mintAmount);
    }

    // ─────────────────────────────────────────────────────────────────────
    // GOVERNANÇA
    // ─────────────────────────────────────────────────────────────────────
    function setGovernance(address newGovernance) external onlyOwner {
        require(newGovernance != address(0));
        governance = newGovernance;
    }

    // ─────────────────────────────────────────────────────────────────────
    // VIEWS
    // ─────────────────────────────────────────────────────────────────────
    function memberCount() external view returns (uint256) { return members.length; }

    function deviation() external view returns (int256) {
        return unwrapSD(sd(int256(unwrap(P))).div(sd(int256(unwrap(F)))).sub(sd(1e18)));
    }

    // ─────────────────────────────────────────────────────────────────────
    // TESTES — remover em produção
    // ─────────────────────────────────────────────────────────────────────
    function _setPriceForTest(uint256 v) external onlyOwner { P = ud(v); }
    function _setFForTest(uint256 v)     external onlyOwner { F = ud(v); }
}
