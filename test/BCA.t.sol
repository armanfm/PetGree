// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {BCA} from "../src/BCA.sol";

contract BCATest is Test {

    BCA     bca;
    address brasil    = makeAddr("brasil");
    address argentina = makeAddr("argentina");
    address externo   = makeAddr("externo");

    uint256 constant ALPHA     = 5e17;
    uint256 constant K         = 15e16;
    uint256 constant ALPHA_EMA = 7e17;
    uint256 constant GDP_ARG   = 3_300_000_000_000;

    function setUp() public {
        bca = new BCA(brasil, ALPHA, K, ALPHA_EMA);
        bca.admitMember(argentina, "AR", GDP_ARG);
    }

    function F() internal view returns (uint256) {
        (bool ok, bytes memory d) = address(bca).staticcall(abi.encodeWithSignature("F()"));
        require(ok); return abi.decode(d, (uint256));
    }
    function P() internal view returns (uint256) {
        (bool ok, bytes memory d) = address(bca).staticcall(abi.encodeWithSignature("P()"));
        require(ok); return abi.decode(d, (uint256));
    }

    function test_Genesis() public view {
        assertEq(F(), 1e18);
        assertEq(P(), 1e18);
        assertEq(bca.deviation(), 0);
        console.log("Supply Brasil:   ", bca.balanceOf(brasil) / 1e18);
        console.log("Supply Argentina:", bca.balanceOf(argentina) / 1e18);
        console.log("Supply total:    ", bca.totalSupply() / 1e18);
    }

    function test_AntiPyramid_SameJurisdiction() public {
        address brasil2 = makeAddr("brasil2");
        bca.admitMember(brasil2, "BR", 1_000_000_000_000);
        vm.prank(brasil);
        vm.expectRevert("BCA: same jurisdiction");
        bca.recordClearing(brasil2, 1000 * 1e18);
    }

    function test_AntiPyramid_NonMember() public {
        vm.prank(brasil);
        vm.expectRevert("BCA: not member");
        bca.transfer(externo, 1000 * 1e18);
    }

    function test_AdmissionRejectsOver50pct() public {
        vm.expectRevert("BCA: exceeds 50% of supply");
        bca.admitMember(makeAddr("china"), "CN", 91_000_000_000_000);
    }

    function test_FRisesWithClearing() public {
        uint256 fBefore = F();
        uint256 amount  = 100_000_000 * 1e18;
        for (uint i = 0; i < 10; i++) {
            vm.prank(brasil);
            bca.recordClearing(argentina, amount);
            vm.prank(argentina);
            bca.recordClearing(brasil, amount);
        }
        bca.updateFundamental();
        assertGt(F(), fBefore);
        console.log("F antes: ", fBefore);
        console.log("F depois:", F());
    }

    function test_Reconvergence() public {
        bca._setFForTest(15e17);
        console.log("F=1.5 P=1.0 desvio inicial:", bca.deviation());
        for (uint i = 0; i < 60; i++) {
            bca.applyReconvergence();
        }
        int256  dev    = bca.deviation();
        uint256 devAbs = dev < 0 ? uint256(-dev) : uint256(dev);
        assertLt(devAbs, 5e16);
        console.log("Desvio final % (deve ser < 5):", devAbs * 100 / 1e18);
    }

    function test_BasinOfAttraction() public {
        uint256[7] memory prices = [
            uint256(1e17), uint256(5e17), uint256(8e17),
            uint256(12e17), uint256(2e18), uint256(4e18), uint256(739e16)
        ];
        for (uint c = 0; c < 7; c++) {
            bca._setFForTest(1e18);
            bca._setPriceForTest(prices[c]);
            for (uint i = 0; i < 100; i++) {
                bca.applyReconvergence();
            }
            int256  dev    = bca.deviation();
            uint256 devAbs = dev < 0 ? uint256(-dev) : uint256(dev);
            assertLt(devAbs, 5e16);
            console.log("Cond", c, "desvio final %:", devAbs * 100 / 1e18);
        }
    }

    function test_StabilityCondition_Theorem1() public {
        BCA bcaStable = new BCA(brasil, 5e17, 15e16, 7e17);
        bcaStable._setFForTest(2e18);
        for (uint i = 0; i < 100; i++) {
            bcaStable.applyReconvergence();
        }
        (bool ok1, bytes memory d1) = address(bcaStable).staticcall(abi.encodeWithSignature("P()"));
        require(ok1);
        uint256 pStable = abi.decode(d1, (uint256));
        uint256 diff = pStable > 2e18 ? pStable - 2e18 : 2e18 - pStable;
        assertLt(diff, 1e17);
        console.log("Estavel (ak=0.075) P final:", pStable);
        vm.expectRevert();
        new BCA(brasil, 1e18, 2e18, 7e17);
        console.log("Deploy com ak>=2 corretamente rejeitado");
    }

    function test_EMA_ResponseSpeed() public {
        uint256 baseAmount = 10_000_000 * 1e18;
        for (uint i = 0; i < 10; i++) {
            vm.prank(brasil);
            bca.recordClearing(argentina, baseAmount);
            vm.prank(argentina);
            bca.recordClearing(brasil, baseAmount);
            bca.updateFundamental();
        }
        uint256 fBase = F();
        console.log("F base:", fBase);
        uint256 shockAmount = baseAmount * 2;
        uint256 fApos5  = 0;
        uint256 fApos15 = 0;
        uint256 fApos30 = 0;
        for (uint i = 0; i < 30; i++) {
            vm.prank(brasil);
            bca.recordClearing(argentina, shockAmount);
            vm.prank(argentina);
            bca.recordClearing(brasil, shockAmount);
            bca.updateFundamental();
            if (i == 4)  fApos5  = F();
            if (i == 14) fApos15 = F();
            if (i == 29) fApos30 = F();
        }
        assertGt(fApos5,  fBase);
        assertGt(fApos15, fApos5);
        assertGt(fApos30, fApos15);
        console.log("F apos  5 passos:", fApos5);
        console.log("F apos 15 passos:", fApos15);
        console.log("F apos 30 passos:", fApos30);
        console.log("F sobe monotonicamente - EMA funcionando corretamente");
    }

    function test_AttackerROI_Negative() public {
        address atacante_BR = makeAddr("atacante_BR");
        address atacante_AR = makeAddr("atacante_AR");
        bca.admitMember(atacante_BR, "BR2", 500_000_000_000);
        bca.admitMember(atacante_AR, "AR2", 500_000_000_000);
        uint256 capitalInicial_BR = bca.balanceOf(atacante_BR);
        uint256 capitalInicial_AR = bca.balanceOf(atacante_AR);
        uint256 capitalTotal      = capitalInicial_BR + capitalInicial_AR;
        console.log("Capital inicial do atacante (tokens):", capitalTotal / 1e18);
        uint256 attackAmount = capitalInicial_BR / 2;
        for (uint i = 0; i < 48; i++) {
            vm.prank(atacante_BR);
            bca.recordClearing(atacante_AR, attackAmount);
            vm.prank(atacante_AR);
            bca.recordClearing(atacante_BR, attackAmount);
            bca.updateFundamental();
            bca.applyReconvergence();
        }
        uint256 capitalFinal = bca.balanceOf(atacante_BR) + bca.balanceOf(atacante_AR);
        console.log("Capital final do atacante (tokens):", capitalFinal / 1e18);
        assertEq(capitalFinal, capitalTotal, "atacante nao ganha tokens - soma zero");
        int256  desvio    = bca.deviation();
        uint256 desvioAbs = desvio < 0 ? uint256(-desvio) : uint256(desvio);
        assertLt(desvioAbs, 15e16, "reconvergencia limita spread P/F mesmo sob ataque");
        console.log("Desvio P/F apos ataque %:", desvioAbs * 100 / 1e18);
        console.log("ROI do atacante: 0% (capital identico, sem spread)");
    }

    // ─────────────────────────────────────────────────────────────────────
    // TESTE 11 — Apreciacao de longo prazo (10 anos / 2520 passos)
    // Volume cresce 7% ao ano. Mostra F_t apreciando ano a ano.
    // ─────────────────────────────────────────────────────────────────────
    function test_LongTermAppreciation() public {
        uint256 volumeDiario = 800_000_000 * 1e18;
        uint256 volumeAtual  = volumeDiario;
        uint256 fInicial     = F();

        console.log("=== Simulacao 10 anos (2520 trading days) ===");
        console.log("F inicial:", fInicial);

        uint256[10] memory fPorAno;

        for (uint dia = 0; dia < 2520; dia++) {
            uint256 saldoBR = bca.balanceOf(brasil);
            uint256 saldoAR = bca.balanceOf(argentina);
            if (saldoBR >= volumeAtual) {
                vm.prank(brasil);
                bca.recordClearing(argentina, volumeAtual);
            }
            if (saldoAR >= volumeAtual) {
                vm.prank(argentina);
                bca.recordClearing(brasil, volumeAtual);
            }
            bca.updateFundamental();
            bca.applyReconvergence();

            // Cresce volume 0.027% ao dia (~7% ao ano)
            volumeAtual = volumeAtual * 1000270 / 1000000;

            if ((dia + 1) % 252 == 0) {
                uint256 ano = (dia + 1) / 252;
                fPorAno[ano - 1] = F();
            }
        }

        uint256 fFinal = F();
        console.log("--- Trajetoria F_t ---");
        for (uint a = 0; a < 10; a++) {
            uint256 apreciacao = fPorAno[a] > fInicial
                ? (fPorAno[a] - fInicial) * 100 / fInicial
                : 0;
            console.log("Ano", a + 1, "F:", fPorAno[a]);
            console.log("  Apreciacao %:", apreciacao);
        }

        uint256 apreciacaoTotal = fFinal > fInicial
            ? (fFinal - fInicial) * 100 / fInicial
            : 0;

        console.log("F final (10 anos):", fFinal);
        console.log("Apreciacao total %:", apreciacaoTotal);

        assertGt(fFinal, fInicial, "F deve apreciar em 10 anos");
        assertGt(fFinal, fInicial / 2, "F nao colapsa");
        assertGt(apreciacaoTotal, 0, "apreciacao total positiva");
    }
}
