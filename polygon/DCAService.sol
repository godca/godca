pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/QuickSwap/QuickSwap-periphery/blob/master/contracts/interfaces/IUniswapV2Router02.sol";
import "https://github.com/QuickSwap/QuickSwap-periphery/blob/master/contracts/interfaces/IUniswapV2Router01.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/AccessControl.sol";

// DCAService contract version deployed on Polygon

contract DCAService is AccessControl {
    address payable public admin;
    uint256 feePercentage = 0;
    uint256 maxSlippage = 5;

    address public zeroExRouter = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;
    address public oneInchRouter = 0x11111112542D85B3EF69AE05771c2dCCff4fAa26;
    address public paraswapRouter = 0x90249ed4d69D70E709fFCd8beE2c5A566f65dADE;
    address public paraswapTokenTransferProxy = 0xCD52384e2A96F6E91e4e420de2F9a8C0f1FFB449;
    address public quickswapRouter = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;

    uint256 public gasOneInch = 500000;
    uint256 public gasZeroEx = 500000;
    uint256 public gasParaswap = 500000;
    uint256 public gasQuickswap = 500000;

    address immutable public MATIC = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address immutable public WMATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    address immutable public WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    bytes32 constant public MANAGER_ROLE = keccak256('MANAGER_ROLE');

    struct DCA {
        address user;
        address fromToken;
        address toToken;
        uint256 startTime;
        uint256 interval;
        uint256 lastSwapTime;
        uint256 amount;
        uint256 numberOfSwaps;
        bool cancelled;
        bool finished;
    }

    DCA[] public DCAList;
    event NewDCA(uint256 indexed id, address indexed user);
    event CancelDCA(uint256 indexed id, address indexed user);

    constructor() {
        admin = payable(msg.sender);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function createDCA(address _fromToken, address _toToken, uint256 _amount, uint256 _interval, uint256 _numberOfSwaps) external {
        DCAList.push(DCA(msg.sender, _fromToken, _toToken, block.timestamp, _interval, 0, _amount, _numberOfSwaps, false, false));
        uint256 _id = DCAList.length - 1;
        emit NewDCA(_id, msg.sender);
    }

    function DCACount() external view returns(uint256) {
        return DCAList.length;
    }

    // function editDCA(uint256 _id, address _from, address _to, uint256 _amount) external {
    //     DCAList[_id].from = _from;
    //     DCAList[_id].to = _to;
    //     DCAList[_id].amount = _amount;
    // }

    function cancelDCA(uint256 _id) external {
        require(msg.sender == DCAList[_id].user, 'not your DCA!');
        DCAList[_id].cancelled = true;
    }

    function finishDCA(uint256 _id) public onlyRole(MANAGER_ROLE) {
        DCAList[_id].finished = true;
    }

    function getTime(uint256 _id) public view returns(uint256) {
        if (DCAList[_id].lastSwapTime + DCAList[_id].interval > block.timestamp) {
            return DCAList[_id].lastSwapTime + DCAList[_id].interval - block.timestamp;
        }
        else {
            return 0;
        }
    }

    function getPermissions(uint256 _id) public view returns(uint256, bool, bool) {
        uint256 balance = IERC20(DCAList[_id].fromToken).balanceOf(DCAList[_id].user);
        uint256 allowance = IERC20(DCAList[_id].fromToken).allowance(DCAList[_id].user, address(this));
        if (balance < allowance) {return (balance, DCAList[_id].cancelled, DCAList[_id].finished);}
        else {return (allowance, DCAList[_id].cancelled, DCAList[_id].finished);}
    }

        // Fee can be max 0.2%!
    function setFee(uint256 _newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newFee < 20);
        feePercentage = _newFee;
    }

    function getGasFeeKoef(uint256 _id, uint256 _outAmount, uint256 _txFee) private view returns(uint256) {
        if (DCAList[_id].toToken == WMATIC) {
            return _outAmount / _txFee;
        }
        else if (DCAList[_id].toToken == WETH) {
            address[] memory path = new address[](2);
            path[0] = WETH;
            path[1] = WMATIC;
            uint256[] memory amountsOut = IUniswapV2Router02(quickswapRouter).getAmountsOut(_outAmount, path);
            return amountsOut[amountsOut.length - 1] / _txFee;
        }
        else {
            address[] memory path = new address[](3);
            path[0] = DCAList[_id].toToken;
            path[1] = WETH;
            path[2] = WMATIC;
            uint256[] memory amountsOut = IUniswapV2Router02(quickswapRouter).getAmountsOut(_outAmount, path);
            return amountsOut[amountsOut.length - 1] / _txFee;
        }
    }

    function getPath(uint256 _id) public view returns(address[] memory) {
        if (DCAList[_id].fromToken == WETH) {
            address[] memory path = new address[](2);
            path[0] = WETH;
            path[1] = DCAList[_id].toToken;
            return path;
        }
        else if (DCAList[_id].toToken == WETH) {
            address[] memory path = new address[](2);
            path[0] = DCAList[_id].fromToken;
            path[1] = WETH;
            return path;
        }
        else {
            address[] memory path = new address[](3);
            path[0] = DCAList[_id].fromToken;
            path[1] = WETH;
            path[2] = DCAList[_id].toToken;
            return path;
        }
    }

        function getPathMatic(uint256 _id) public view returns(address[] memory) {
        if (DCAList[_id].fromToken == WETH) {
            address[] memory path = new address[](2);
            path[0] = WETH;
            path[1] = WMATIC;
            return path;
        }
        else {
            address[] memory path = new address[](3);
            path[0] = DCAList[_id].fromToken;
            path[1] = WETH;
            path[2] = WMATIC;
            return path;
        }
    }

    function getQuickswapPrice(uint256 _id) public view returns(uint256) {
        address[] memory path;
        if (DCAList[_id].toToken == MATIC) {
            path = getPathMatic(_id);
        }
        else {
            path = getPath(_id);
        }
        uint256[] memory amountsOut = IUniswapV2Router02(quickswapRouter).getAmountsOut(DCAList[_id].amount, path);
        return amountsOut[amountsOut.length - 1];
    }

    function preSwapChecks(uint256 _id) private view returns(uint256) {
        require(getTime(_id) == 0 &&
        DCAList[_id].numberOfSwaps > 0 &&
        DCAList[_id].cancelled == false &&
        DCAList[_id].finished == false);
        uint256 minOut = getQuickswapPrice(_id);
        minOut -= minOut * maxSlippage / 100;
        return minOut;
    }

    function structDCAUpdate(uint256 _id) private {
        DCAList[_id].lastSwapTime = block.timestamp;
        DCAList[_id].numberOfSwaps--;
        if (DCAList[_id].numberOfSwaps == 0) {
            finishDCA(_id);
        }
    }

    function gasFeeTransfer(uint256 _outAmount, uint256 _id, uint256 _gasAmount) private {
        require(_gasAmount < 2000000, 'gasAmount too high!');
        uint256 txFee = _gasAmount * tx.gasprice;
        uint256 koef = getGasFeeKoef(_id, _outAmount, txFee);
        uint256 totalFee = _outAmount / koef + _outAmount * feePercentage / 10000;
        require(IERC20(DCAList[_id].toToken).transfer(admin, totalFee));
        require(IERC20(DCAList[_id].toToken).transfer(DCAList[_id].user, _outAmount - totalFee));
    }

    function gasFeeTransferMatic(uint256 _outAmount, uint256 _id, uint256 _gasAmount) private {
        require(_gasAmount < 2000000, 'gasAmount too high!');
        uint256 txFee = _gasAmount * tx.gasprice;
        uint256 koef = _outAmount / txFee;
        uint256 totalFee = _outAmount / koef + _outAmount * feePercentage / 10000;
        (bool feeResult,) = admin.call{value: totalFee, gas: 6000}("");
        require(feeResult, 'MATIC fee transfer failed!');
        (bool swapResult,) = DCAList[_id].user.call{value: _outAmount - totalFee, gas: 6000}("");
        require(swapResult, 'MATIC transfer to user failed!');
    }

    function swapOnOneInch(uint256 _id, uint256 _gasAmount, bytes calldata _data) public onlyRole(MANAGER_ROLE) {
        uint256 minOut = preSwapChecks(_id);

        structDCAUpdate(_id);

        IERC20(DCAList[_id].fromToken).transferFrom(DCAList[_id].user, address(this), DCAList[_id].amount);
        IERC20(DCAList[_id].fromToken).approve(oneInchRouter, DCAList[_id].amount);

        (bool success, bytes memory returnData) = oneInchRouter.call(_data);
        if (success) {
            (uint256 outAmount,) = abi.decode(returnData, (uint, uint));
            require(outAmount > minOut, 'slippage too low!');

            gasFeeTransfer(outAmount, _id, _gasAmount);
        }
        else {
            revert();
        }
    }

        function swapOnParaswap(uint256 _id, uint256 _gasAmount, bytes calldata _data) external onlyRole(MANAGER_ROLE) {
            uint256 minOut = preSwapChecks(_id);

            structDCAUpdate(_id);

            IERC20(DCAList[_id].fromToken).transferFrom(DCAList[_id].user, address(this), DCAList[_id].amount);
            IERC20(DCAList[_id].fromToken).approve(paraswapTokenTransferProxy, DCAList[_id].amount);

            (bool success, bytes memory returnData) = paraswapRouter.call(_data);
            if (success) {
                (uint256 outAmount) = abi.decode(returnData, (uint));
                require(outAmount > minOut, 'slippage too low!');

                gasFeeTransfer(outAmount, _id, _gasAmount);
            }
            else {
                revert();
            }
        }

        function swapOnZeroEx(uint256 _id, uint256 _gasAmount, bytes calldata _data) external onlyRole(MANAGER_ROLE) {
            uint256 minOut = preSwapChecks(_id);

            structDCAUpdate(_id);

            IERC20(DCAList[_id].fromToken).transferFrom(DCAList[_id].user, address(this), DCAList[_id].amount);
            IERC20(DCAList[_id].fromToken).approve(zeroExRouter, DCAList[_id].amount);

            (bool success, bytes memory returnData) = zeroExRouter.call(_data);
            if (success) {
                (uint256 outAmount) = abi.decode(returnData, (uint));
                require(outAmount > minOut, 'slippage too low!');

                gasFeeTransfer(outAmount, _id, _gasAmount);
            }
            else {
                revert();
            }
        }

        function swapOnQuickswap(uint256 _id, uint256 _gasAmount) public onlyRole(MANAGER_ROLE) {
            uint256 minOut = preSwapChecks(_id);

            structDCAUpdate(_id);

            IERC20(DCAList[_id].fromToken).transferFrom(DCAList[_id].user, address(this), DCAList[_id].amount);
            IERC20(DCAList[_id].fromToken).approve(quickswapRouter, DCAList[_id].amount);

            uint256[] memory outAmounts = IUniswapV2Router02(quickswapRouter).swapExactTokensForTokens(
            DCAList[_id].amount,
            minOut,
            getPath(_id),
            address(this),
            block.timestamp + 900);
            uint256 outAmount = outAmounts[outAmounts.length - 1];
            require(outAmount > minOut, 'slippage too low!');

            gasFeeTransfer(outAmount, _id, _gasAmount);
        }

        function swapOnOneInchMatic(uint256 _id, uint256 _gasAmount, bytes calldata _data) public onlyRole(MANAGER_ROLE) {
            uint256 minOut = preSwapChecks(_id);

            structDCAUpdate(_id);

            IERC20(DCAList[_id].fromToken).transferFrom(DCAList[_id].user, address(this), DCAList[_id].amount);
            IERC20(DCAList[_id].fromToken).approve(oneInchRouter, DCAList[_id].amount);

            (bool success, bytes memory returnData) = oneInchRouter.call(_data);
            if (success) {
                (uint256 outAmount,) = abi.decode(returnData, (uint, uint));
                require(outAmount > minOut, 'slippage too low!');

                gasFeeTransferMatic(outAmount, _id, _gasAmount);
            }
            else {
                revert();

            }
        }

        function swapOnParaswapMatic(uint256 _id, uint256 _gasAmount, bytes calldata _data) external onlyRole(MANAGER_ROLE) {
            uint256 minOut = preSwapChecks(_id);

            structDCAUpdate(_id);

            IERC20(DCAList[_id].fromToken).transferFrom(DCAList[_id].user, address(this), DCAList[_id].amount);
            IERC20(DCAList[_id].fromToken).approve(paraswapTokenTransferProxy, DCAList[_id].amount);

            (bool success, bytes memory returnData) = paraswapRouter.call(_data);
            if (success) {
                (uint256 outAmount) = abi.decode(returnData, (uint));
                require(outAmount > minOut, 'slippage too low!');

                gasFeeTransferMatic(outAmount, _id, _gasAmount);
            }
            else {
                revert();

            }
        }

        function swapOnZeroExMatic(uint256 _id, uint256 _gasAmount, bytes calldata _data) external onlyRole(MANAGER_ROLE) {
            uint256 minOut = preSwapChecks(_id);

            structDCAUpdate(_id);

            IERC20(DCAList[_id].fromToken).transferFrom(DCAList[_id].user, address(this), DCAList[_id].amount);
            IERC20(DCAList[_id].fromToken).approve(zeroExRouter, DCAList[_id].amount);

            (bool success, bytes memory returnData) = zeroExRouter.call(_data);
            if (success) {
                (uint256 outAmount) = abi.decode(returnData, (uint));
                require(outAmount > minOut, 'slippage too low!');

                gasFeeTransferMatic(outAmount, _id, _gasAmount);
            }
            else {
                revert();
            }
        }

        function swapOnQuickswapMatic(uint256 _id, uint256 _gasAmount) public onlyRole(MANAGER_ROLE) {
            uint256 minOut = preSwapChecks(_id);

            structDCAUpdate(_id);

            IERC20(DCAList[_id].fromToken).transferFrom(DCAList[_id].user, address(this), DCAList[_id].amount);
            IERC20(DCAList[_id].fromToken).approve(quickswapRouter, DCAList[_id].amount);

            address[] memory path = new address[](3);
            path[0] = DCAList[_id].fromToken;
            path[1] = WETH;
            path[2] = WMATIC;

            uint256[] memory outAmounts = IUniswapV2Router02(quickswapRouter).swapExactTokensForTokens(
            DCAList[_id].amount,
            minOut,
            path,
            address(this),
            block.timestamp + 900);
            uint256 outAmount = outAmounts[outAmounts.length - 1];
            require(outAmount > minOut, 'slippage too low!');

            gasFeeTransferMatic(outAmount, _id, _gasAmount);
        }
    }