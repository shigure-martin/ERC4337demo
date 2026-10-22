// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IFeePolicy } from "./interfaces/IFeePolicy.sol";

contract FeePolicy is AccessControl, IFeePolicy {
    bytes32 public constant FEE_ADMIN_ROLE = keccak256("FEE_ADMIN_ROLE");

    address public immutable override usdt;
    address public override feeCollector;
    uint256 public maxFeeUSDT;

    error ZeroAddress();
    error InvalidTokenPair(address sellToken, address buyToken, address usdt);
    error InvalidFee(uint256 feeUSDT, uint256 maxFeeUSDT);
    error FeeExceedsPolicy(uint256 requestedFee, uint256 policyLimit);
    error ZeroAmount();

    event FeeCollectorChanged(address indexed previousCollector, address indexed newCollector);
    event MaxFeeChanged(uint256 previousLimit, uint256 newLimit);

    constructor(address admin, address usdt_, address feeCollector_, uint256 maxFeeUSDT_) {
        if (admin == address(0) || usdt_ == address(0) || feeCollector_ == address(0)) {
            revert ZeroAddress();
        }
        if (maxFeeUSDT_ == 0) revert ZeroAmount();

        usdt = usdt_;
        feeCollector = feeCollector_;
        maxFeeUSDT = maxFeeUSDT_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FEE_ADMIN_ROLE, admin);
    }

    function validateFee(address sellToken, address buyToken, uint256 feeUSDT, uint256 maxFeeUSDT_)
        external
        view
        returns (address collector)
    {
        if (sellToken == buyToken || (sellToken != usdt && buyToken != usdt)) {
            revert InvalidTokenPair(sellToken, buyToken, usdt);
        }
        if (feeUSDT == 0 || maxFeeUSDT_ == 0 || feeUSDT > maxFeeUSDT_) {
            revert InvalidFee(feeUSDT, maxFeeUSDT_);
        }
        if (maxFeeUSDT_ > maxFeeUSDT) {
            revert FeeExceedsPolicy(feeUSDT, maxFeeUSDT);
        }

        return feeCollector;
    }

    function setFeeCollector(address newCollector) external onlyRole(FEE_ADMIN_ROLE) {
        if (newCollector == address(0)) revert ZeroAddress();

        address previousCollector = feeCollector;
        feeCollector = newCollector;

        emit FeeCollectorChanged(previousCollector, newCollector);
    }

    function setMaxFeeUSDT(uint256 newLimit) external onlyRole(FEE_ADMIN_ROLE) {
        if (newLimit == 0) revert ZeroAmount();

        uint256 previousLimit = maxFeeUSDT;
        maxFeeUSDT = newLimit;

        emit MaxFeeChanged(previousLimit, newLimit);
    }
}
