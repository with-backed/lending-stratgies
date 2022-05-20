// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {ERC721, ERC721TokenReceiver} from 'solmate/tokens/ERC721.sol';
import {SafeTransferLib, ERC20} from "solmate/utils/SafeTransferLib.sol";

import {INFTLoanFacilitator} from './interfaces/INFTLoanFacilitator.sol';

struct LoanTerms {
    bool allowBuyouts;
    bool allowLoanAmountIncrease;
    uint16 interestRate;
    uint128 amount;
    uint32 durationSeconds;
    address loanAsset;
}

interface NFTLoanTermsSource {
    function terms(uint256 tokenId, address nft, address loanAsset, bytes calldata data) external returns (LoanTerms memory);
}

contract LendController is ERC721TokenReceiver {
    using SafeTransferLib for ERC20;
    
    struct LenderSpec {
        address lender;
        uint256 amount;
        bool pull;
    }

    struct BorrowRequest {
        LenderSpec[] lendersSpecs;
        address termsSource;
        LoanTerms terms;
    }

    uint256 ONE = 1e18;
    mapping(address => mapping(address => bool)) public termsApprovals;
    mapping(address => mapping(address => uint256)) public lenderBalance;
    mapping(uint256 => mapping(address => uint256)) public lenderLoanShares;

    INFTLoanFacilitator public loanFacilitator;

    constructor(INFTLoanFacilitator _facilitator) {
        loanFacilitator = _facilitator;
    }

    event SetTermsApproval(address indexed from, address indexed termsContract, bool approved);

    function setTermsApproval(address termsContract, bool approved) external {
        termsApprovals[msg.sender][termsContract] = approved;

        emit SetTermsApproval(msg.sender, termsContract, approved);
    }

    function purchaseNFT() external {
        // allows anyone to call in and seize a seize NFT that
        // the controller holds the lend ticket for and pays the lenders
        // purchase price must be >= totalOwed on loan
    }

    function liquidateNFT(uint256 loanId) external {
        // TBD if controller will have one liquidation mechanism 
        // or will call out to the terms contract for implement
        // update lenderBalance based on lenderLoanShares * sale value 
    }

    function lend(
        uint256 loanId,
        uint256 tokenId,
        address nft,
        BorrowRequest memory request,
        bytes calldata data
    ) external {
        _lend(loanId, tokenId, nft, request, false, data);
    }

    function _lend(
        uint256 loanId,
        uint256 tokenId,
        address nft,
        BorrowRequest memory request,
        bool skipIsBuyoutCheck,
        bytes calldata data
    ) internal {
        LoanTerms memory terms = NFTLoanTermsSource(request.termsSource).terms(tokenId, msg.sender, request.terms.loanAsset, '');

        ERC20 loanAsset = ERC20(request.terms.loanAsset);
        uint256 lenderTotal;

        for(uint i = 0; i < request.lendersSpecs.length; i++) {
            LenderSpec memory info = request.lendersSpecs[i];
            require(termsApprovals[info.lender][request.termsSource], 'lender has not approved terms source');

            if(info.pull) {
                ERC20(request.terms.loanAsset).safeTransferFrom(info.lender, address(this), info.amount);
            } else {
                lenderBalance[info.lender][address(loanAsset)] -= info.amount;
            }
            lenderTotal += info.amount;

            lenderLoanShares[loanId][info.lender] = info.amount * ONE / terms.amount;
        }

        loanAsset.approve(address(loanFacilitator), type(uint256).max);

        if(skipIsBuyoutCheck){
            require(lenderTotal == terms.amount);
        } else {
            (,,, uint40 lastAccumulatedTimestamp,,,,,,,) = loanFacilitator.loanInfo(loanId);
            
            if(lastAccumulatedTimestamp != 0) {
                require(terms.allowBuyouts);
                require(lenderTotal == terms.amount + loanFacilitator.interestOwed(loanId));
            } else {
                require(lenderTotal == terms.amount);
            }
        }

        loanFacilitator.lend(
            loanId,
            terms.interestRate,
            terms.amount,
            terms.durationSeconds,
            address(this)
        );
    }

    // used to create loan and 
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        BorrowRequest memory request = abi.decode(data, (BorrowRequest));

        ERC721(msg.sender).setApprovalForAll(address(loanFacilitator), true);

        uint256 loanId = loanFacilitator.createLoan(
            tokenId, 
            msg.sender, 
            request.terms.interestRate, 
            request.terms.allowLoanAmountIncrease, 
            request.terms.amount, 
            request.terms.loanAsset, 
            request.terms.durationSeconds, 
            from
        );
        
        _lend(loanId, tokenId, msg.sender, request, true, data);

        return ERC721TokenReceiver.onERC721Received.selector;
    }
}
