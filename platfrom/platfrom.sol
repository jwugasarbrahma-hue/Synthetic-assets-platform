// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SyntheticAssetsPlus
 * @dev A platform for creating and managing synthetic assets backed by collateral
 */
contract SyntheticAssetsPlus is ReentrancyGuard, Ownable {
    
    struct SyntheticAsset {
        string symbol;
        uint256 price;          // Price in USD (18 decimals)
        uint256 totalSupply;
        bool isActive;
        uint256 collateralRatio; // Required collateral ratio (150% = 1500)
    }
    
    struct Position {
        uint256 collateralAmount;
        uint256 syntheticAmount;
        uint256 lastUpdatePrice;
        bool isLiquidatable;
    }
    
    // Mappings
    mapping(bytes32 => SyntheticAsset) public syntheticAssets;
    mapping(address => mapping(bytes32 => Position)) public userPositions;
    mapping(bytes32 => uint256) public assetPrices;
    
    // State variables
    IERC20 public collateralToken; // USDC or similar stablecoin
    bytes32[] public assetSymbols;
    uint256 public liquidationPenalty = 500; // 5%
    uint256 public constant PRICE_PRECISION = 1e18;
    uint256 public constant RATIO_PRECISION = 10000; // 100% = 10000
    
    // Events
    event AssetCreated(bytes32 indexed symbol, uint256 price, uint256 collateralRatio);
    event PositionOpened(address indexed user, bytes32 indexed asset, uint256 collateral, uint256 synthetic);
    event PositionClosed(address indexed user, bytes32 indexed asset, uint256 collateral, uint256 synthetic);
    event PriceUpdated(bytes32 indexed asset, uint256 oldPrice, uint256 newPrice);
    event PositionLiquidated(address indexed user, bytes32 indexed asset, address indexed liquidator);
    
    constructor(address _collateralToken) Ownable(msg.sender) {
        collateralToken = IERC20(_collateralToken);
    }
    
    /**
     * @dev Creates a new synthetic asset
     * @param symbol Asset symbol (e.g., "sBTC", "sETH")
     * @param initialPrice Initial price in USD
     * @param collateralRatio Required collateral ratio (e.g., 1500 for 150%)
     */
    function createSyntheticAsset(
        string memory symbol,
        uint256 initialPrice,
        uint256 collateralRatio
    ) external onlyOwner {
        require(initialPrice > 0, "Price must be positive");
        require(collateralRatio >= 1100, "Collateral ratio too low"); // Minimum 110%
        
        bytes32 assetId = keccak256(abi.encodePacked(symbol));
        require(!syntheticAssets[assetId].isActive, "Asset already exists");
        
        syntheticAssets[assetId] = SyntheticAsset({
            symbol: symbol,
            price: initialPrice,
            totalSupply: 0,
            isActive: true,
            collateralRatio: collateralRatio
        });
        
        assetPrices[assetId] = initialPrice;
        assetSymbols.push(assetId);
        
        emit AssetCreated(assetId, initialPrice, collateralRatio);
    }
    
    /**
     * @dev Mints synthetic assets by depositing collateral
     * @param assetSymbol Symbol of the synthetic asset to mint
     * @param collateralAmount Amount of collateral to deposit
     * @param syntheticAmount Amount of synthetic assets to mint
     */
    function mintSyntheticAsset(
        string memory assetSymbol,
        uint256 collateralAmount,
        uint256 syntheticAmount
    ) external nonReentrant {
        bytes32 assetId = keccak256(abi.encodePacked(assetSymbol));
        SyntheticAsset storage asset = syntheticAssets[assetId];
        require(asset.isActive, "Asset not found or inactive");
        require(collateralAmount > 0 && syntheticAmount > 0, "Invalid amounts");
        
        // Calculate required collateral
        uint256 syntheticValueUSD = (syntheticAmount * asset.price) / PRICE_PRECISION;
        uint256 requiredCollateral = (syntheticValueUSD * asset.collateralRatio) / RATIO_PRECISION;
        require(collateralAmount >= requiredCollateral, "Insufficient collateral");
        
        // Transfer collateral from user
        require(
            collateralToken.transferFrom(msg.sender, address(this), collateralAmount),
            "Collateral transfer failed"
        );
        
        // Update user position
        Position storage position = userPositions[msg.sender][assetId];
        position.collateralAmount += collateralAmount;
        position.syntheticAmount += syntheticAmount;
        position.lastUpdatePrice = asset.price;
        
        // Update total supply
        asset.totalSupply += syntheticAmount;
        
        emit PositionOpened(msg.sender, assetId, collateralAmount, syntheticAmount);
    }
    
    /**
     * @dev Burns synthetic assets and withdraws collateral
     * @param assetSymbol Symbol of the synthetic asset to burn
     * @param syntheticAmount Amount of synthetic assets to burn
     */
    function burnSyntheticAsset(
        string memory assetSymbol,
        uint256 syntheticAmount
    ) external nonReentrant {
        bytes32 assetId = keccak256(abi.encodePacked(assetSymbol));
        Position storage position = userPositions[msg.sender][assetId];
        require(position.syntheticAmount >= syntheticAmount, "Insufficient synthetic balance");
        
        SyntheticAsset storage asset = syntheticAssets[assetId];
        
        // Calculate collateral to return (proportional)
        uint256 collateralToReturn = (position.collateralAmount * syntheticAmount) / position.syntheticAmount;
        
        // Update position
        position.collateralAmount -= collateralToReturn;
        position.syntheticAmount -= syntheticAmount;
        
        // Update total supply
        asset.totalSupply -= syntheticAmount;
        
        // Transfer collateral back to user
        require(collateralToken.transfer(msg.sender, collateralToReturn), "Collateral transfer failed");
        
        emit PositionClosed(msg.sender, assetId, collateralToReturn, syntheticAmount);
    }
    
    /**
     * @dev Updates the price of a synthetic asset (in production, this would use oracles)
     * @param assetSymbol Symbol of the asset to update
     * @param newPrice New price in USD
     */
    function updateAssetPrice(
        string memory assetSymbol,
        uint256 newPrice
    ) external onlyOwner {
        bytes32 assetId = keccak256(abi.encodePacked(assetSymbol));
        require(syntheticAssets[assetId].isActive, "Asset not found");
        require(newPrice > 0, "Invalid price");
        
        uint256 oldPrice = syntheticAssets[assetId].price;
        syntheticAssets[assetId].price = newPrice;
        assetPrices[assetId] = newPrice;
        
        emit PriceUpdated(assetId, oldPrice, newPrice);
    }
    
    /**
     * @dev Liquidates an undercollateralized position
     * @param user Address of the user to liquidate
     * @param assetSymbol Symbol of the synthetic asset
     */
    function liquidatePosition(
        address user,
        string memory assetSymbol
    ) external nonReentrant {
        bytes32 assetId = keccak256(abi.encodePacked(assetSymbol));
        Position storage position = userPositions[user][assetId];
        SyntheticAsset storage asset = syntheticAssets[assetId];
        
        require(position.syntheticAmount > 0, "No position to liquidate");
        
        // Check if position is undercollateralized
        uint256 syntheticValueUSD = (position.syntheticAmount * asset.price) / PRICE_PRECISION;
        uint256 requiredCollateral = (syntheticValueUSD * asset.collateralRatio) / RATIO_PRECISION;
        require(position.collateralAmount < requiredCollateral, "Position not liquidatable");
        
        // Calculate liquidation penalty
        uint256 penalty = (position.collateralAmount * liquidationPenalty) / RATIO_PRECISION;
        uint256 liquidatorReward = penalty / 2; // Half goes to liquidator
        uint256 protocolFee = penalty - liquidatorReward;
        
        // Transfer rewards
        uint256 remainingCollateral = position.collateralAmount - penalty;
        require(collateralToken.transfer(msg.sender, liquidatorReward), "Liquidator reward failed");
        require(collateralToken.transfer(owner(), protocolFee), "Protocol fee failed");
        require(collateralToken.transfer(user, remainingCollateral), "Remaining collateral failed");
        
        // Update total supply and clear position
        asset.totalSupply -= position.syntheticAmount;
        delete userPositions[user][assetId];
        
        emit PositionLiquidated(user, assetId, msg.sender);
    }
    
    // View functions
    function getPosition(address user, string memory assetSymbol) 
        external 
        view 
        returns (uint256 collateral, uint256 synthetic, uint256 lastPrice, bool liquidatable) 
    {
        bytes32 assetId = keccak256(abi.encodePacked(assetSymbol));
        Position memory position = userPositions[user][assetId];
        return (position.collateralAmount, position.syntheticAmount, position.lastUpdatePrice, position.isLiquidatable);
    }
    
    function getAssetInfo(string memory assetSymbol)
        external
        view
        returns (string memory symbol, uint256 price, uint256 totalSupply, bool isActive, uint256 collateralRatio)
    {
        bytes32 assetId = keccak256(abi.encodePacked(assetSymbol));
        SyntheticAsset memory asset = syntheticAssets[assetId];
        return (asset.symbol, asset.price, asset.totalSupply, asset.isActive, asset.collateralRatio);
    }
}
