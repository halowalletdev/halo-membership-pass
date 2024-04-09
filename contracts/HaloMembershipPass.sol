// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./EventsAndErrors.sol";

/**
 * HaloMembershipPass: each pass is an ERC721 token, and includes level information
 */
contract HaloMembershipPass is
    EventsAndErrors,
    Initializable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    Ownable2StepUpgradeable,
    ERC721Upgradeable
{
    uint256 public constant SCALE_DECIMAL = 100;
    uint256 public constant MAX_LEVEL = 6;

    /// Addition variables ///
    string private _baseURIextended; // notice: end with "/"

    uint256 public currentIndex; // current tokenId(number) of "minted" (start from 1.）
    uint256 public totalSupplyAll; // total number of each level
    mapping(uint8 level => uint256) public totalSupply;
    uint256 public level5and6Proportion; // the upper limit of the percentage of level5 and level6
    mapping(uint256 tokenId => uint8 level) public levelOfToken; // the level of each token

    mapping(address user => bool) public isMinted; // whether  user has participated in mint activities
    uint256 public publicMintUpperLimit; // the upper limit of "public mint activity"

    address public payCurrency; // the currency of mint fee
    uint256 public price; // the price of minting an nft
    address public feeRecipient;

    uint256 public startTimestamp;
    bytes32 public initialMintMerkleRoot;
    mapping(uint256 campaignId => bytes32 root) public campaignMerkleRoot;
    mapping(uint256 newTokenId => uint256 oldTokenId) public upgradedFrom;
    mapping(address => uint256) public userMainProfile; // user address--> main tokenId

    address public adminSigner;

    modifier callerIsUser() {
        require(tx.origin == msg.sender, "The caller is another contract");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        address feeRecipient_,
        uint256 level5and6Proportion_
    ) public initializer {
        feeRecipient = feeRecipient_;
        level5and6Proportion = level5and6Proportion_;

        __ReentrancyGuard_init();
        __Pausable_init();
        __Ownable2Step_init();
        __ERC721_init(name_, symbol_);
    }

    /////////////////// external functions ///////////////////
    receive() external payable {}

    /// @notice Participate in the initial mint activity
    /// @param proof The merkle proof for msg.sender
    /// @param nftLevels level of each nft, the length of array is the number of NFTs finally received by the user
    /// @param discount Percentage scale: 90 means 10% off, 100 means no discount
    function initialMint(
        bytes32[] calldata proof,
        uint8[] calldata nftLevels,
        uint256 discount
    ) external payable callerIsUser nonReentrant whenNotPaused {
        // Verify parameters
        require(
            initialMintMerkleRoot != 0x0 && block.timestamp >= startTimestamp,
            "Not in initial mint period"
        );
        require(
            proof.length > 0 &&
                nftLevels.length > 0 &&
                discount <= SCALE_DECIMAL,
            "Invalid parameters"
        );

        require(!isMinted[msg.sender], "Already Minted");
        //  Merkle verify
        bytes32 leaf = keccak256(abi.encode(msg.sender, nftLevels, discount));
        require(
            MerkleProof.verify(proof, initialMintMerkleRoot, leaf),
            "Invalid proof"
        );
        // Mark it minted
        isMinted[msg.sender] = true;

        // Charge the mint fee
        uint256 nftAmount = nftLevels.length;
        uint256 payAmount = (nftAmount * price * discount) / SCALE_DECIMAL;
        _chargeMintFee(payAmount);

        // Mint tokens
        for (uint256 i = 0; i < nftAmount; i++) {
            uint256 newTokenId = ++currentIndex;
            uint8 newTokenLevel = nftLevels[i];
            // 1.set level 2.mint (can not change the order)
            require(
                newTokenLevel > 0 && newTokenLevel <= MAX_LEVEL,
                "Invalid level"
            );
            levelOfToken[newTokenId] = newTokenLevel;
            _safeMint(msg.sender, newTokenId);
            emit InitialMinted(msg.sender, newTokenId, newTokenLevel);
        }
    }

    /// @notice Participate in the level 1 mint activity
    /// @param discount Percentage scale: 90 means 10% off, 100 means no discount
    /// @param sigExpiredAt The expiration time of adminSig
    /// @param adminSig The admin signature for msg.sender
    function publicMint(
        uint256 discount,
        uint256 sigExpiredAt,
        bytes calldata adminSig
    ) external payable callerIsUser nonReentrant whenNotPaused {
        // Verify parameters
        require(adminSigner != address(0), "Invalid signer");
        require(
            adminSig.length > 0 &&
                sigExpiredAt > block.timestamp &&
                discount <= SCALE_DECIMAL,
            "Invalid parameters"
        );
        // Verify signature
        require(
            verifyAdminSig(
                keccak256(abi.encode(msg.sender, discount, sigExpiredAt)),
                adminSig
            ),
            "Invalid signature"
        );

        require(!isMinted[msg.sender], "Already Minted");
        require(publicMintUpperLimit > 0, "Exceed limit");

        // Mark it minted
        isMinted[msg.sender] = true;
        publicMintUpperLimit--;

        // Charge the mint fee
        _chargeMintFee((price * discount) / SCALE_DECIMAL);
        // Mint a level1 nft
        uint256 newTokenId = ++currentIndex;
        levelOfToken[newTokenId] = 1;
        _safeMint(msg.sender, newTokenId);

        emit PublicMinted(msg.sender, newTokenId, 1);
    }

    /// @notice Upgrade the main profile nft
    /// @param proof The merkle proof for msg.sender
    /// @param campaignId The campaign that the user participated in
    /// @param toLevel The level to upgrade to
    function upgradeMainProfile(
        bytes32[] calldata proof,
        uint256 campaignId,
        uint8 toLevel
    ) external nonReentrant whenNotPaused {
        // Verify parameters
        require(
            proof.length > 0 &&
                campaignMerkleRoot[campaignId] != 0x0 &&
                toLevel <= MAX_LEVEL,
            "Invalid parameters"
        );

        // Limit the maximum quantity
        if (toLevel >= 5) {
            require(
                totalSupply[5] + totalSupply[6] <
                    (totalSupplyAll * level5and6Proportion) / SCALE_DECIMAL,
                "Exceed the target proportion"
            );
        }
        // the main profile nft is used by default
        uint256 tokenId = userMainProfile[msg.sender];
        require(
            tokenId != 0 && ownerOf(tokenId) == msg.sender,
            "Not user's main profile"
        );
        require(toLevel == levelOfToken[tokenId] + 1, "Invalid target level");

        // Merkle verify
        bytes32 leaf = keccak256(abi.encode(msg.sender, tokenId, toLevel));
        require(
            MerkleProof.verify(proof, campaignMerkleRoot[campaignId], leaf),
            "Invalid proof"
        );

        // Upgrade：1.burn old token 2.mint new token
        _burn(tokenId); // unbind main profile simultaneously
        uint256 newTokenId = ++currentIndex;
        levelOfToken[newTokenId] = toLevel;
        _safeMint(msg.sender, newTokenId);
        // bind the new token as main profile(because the old main profile has burnt)
        userMainProfile[msg.sender] = newTokenId;
        upgradedFrom[newTokenId] = tokenId;

        emit NFTUpgraded(msg.sender, tokenId, newTokenId, toLevel);
        emit MainProfileSet(msg.sender, newTokenId);
    }

    /// @notice Bind an nft held by user as main nft
    function bindMainProfile(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "Not token owner");
        userMainProfile[msg.sender] = tokenId;
        emit MainProfileSet(msg.sender, tokenId);
    }

    /// @notice Unbind the main nft
    function unbindMainProfile() external {
        userMainProfile[msg.sender] = 0;
        emit MainProfileSet(msg.sender, 0);
    }

    function burn(uint256 tokenId) public {
        require(
            _isApprovedOrOwner(msg.sender, tokenId),
            "Not token owner or approved"
        );
        _burn(tokenId);
    }

    //////////////// public functions /////////////////
    function canUpgradeToLevel5orLevel6() public view returns (bool) {
        return
            totalSupply[5] + totalSupply[6] <
            (totalSupplyAll * level5and6Proportion) / SCALE_DECIMAL;
    }

    function ownersOf(
        uint256[] memory tokenIds
    ) public view returns (address[] memory) {
        uint256 count = tokenIds.length;
        address[] memory ownerList = new address[](count);
        // loop
        for (uint256 i = 0; i < count; i++) {
            try this.ownerOf(tokenIds[i]) returns (address user) {
                ownerList[i] = user;
            } catch (bytes memory) {
                ownerList[i] = address(0);
            }
        }
        return ownerList;
    }

    function verifyMerkleProof(
        bytes32[] memory proof,
        bytes32 root,
        bytes32 leaf
    ) public pure returns (bool) {
        return MerkleProof.verify(proof, root, leaf);
    }

    function verifyAdminSig(
        bytes32 messageHash,
        bytes calldata inputSig
    ) public view returns (bool) {
        bytes32 hashToSign = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        address signer = ECDSA.recover(hashToSign, inputSig);
        return signer == adminSigner;
    }

    /////////// owner's functions ////////////////////////
    function adminMint(
        uint8[] calldata nftLevels,
        address receiver
    ) external onlyOwner {
        uint256 amount = nftLevels.length;

        for (uint256 i = 0; i < amount; i++) {
            uint256 newTokenId = ++currentIndex;
            uint8 newTokenLevel = nftLevels[i];
            // 1.set level 2.mint (can not change the order)
            require(
                newTokenLevel > 0 && newTokenLevel <= MAX_LEVEL,
                "Invalid level"
            );
            levelOfToken[newTokenId] = newTokenLevel;
            _safeMint(receiver, newTokenId);
            emit AdminMinted(receiver, newTokenId, newTokenLevel);
        }
    }

    function setAdminSigner(address newSigner) external onlyOwner {
        adminSigner = newSigner;
    }

    function setBaseURI(string memory baseURI_) external onlyOwner {
        _baseURIextended = baseURI_;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid recipient");
        feeRecipient = newRecipient;
    }

    function setLevel5and6Proportion(uint256 newProportion) external onlyOwner {
        require(newProportion <= 100, "Invalid proportion");
        level5and6Proportion = newProportion;
    }

    function setInitialMintParams(
        bytes32 newRoot,
        uint256 newStartTimestamp
    ) external onlyOwner {
        initialMintMerkleRoot = newRoot;
        startTimestamp = newStartTimestamp;
    }

    function setCampaignMerkleRoot(
        uint256 campaignId,
        bytes32 campaignRoot
    ) external onlyOwner {
        campaignMerkleRoot[campaignId] = campaignRoot;
    }

    function setPublicMintUpperLimit(uint256 newLimit) external onlyOwner {
        publicMintUpperLimit = newLimit;
    }

    function setPayCurrencyAndPrice(
        address newCurrency,
        uint256 newPrice
    ) external onlyOwner {
        payCurrency = newCurrency;
        price = newPrice;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function withdraw(address payable to) external payable onlyOwner {
        (bool success, ) = to.call{value: address(this).balance}("");
        require(success);
    }

    ////////// internal and private functions //////////////////////////
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 firstTokenId,
        uint256 /*batchSize*/
    ) internal override {
        uint8 level = levelOfToken[firstTokenId];
        if (from == address(0)) {
            totalSupply[level] += 1;
            totalSupplyAll += 1;
        }
        if (to == address(0)) {
            uint256 supply = totalSupply[level];
            require(supply >= 1, "ERC1155: burn amount exceeds totalSupply");
            unchecked {
                totalSupply[level] -= 1;
                totalSupplyAll -= 1;
            }
        }
        // unbind the main profile
        if (userMainProfile[from] == firstTokenId) {
            userMainProfile[from] = 0;
            emit MainProfileSet(from, 0);
        }
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseURIextended;
    }

    function _chargeMintFee(uint256 payAmount) internal {
        if (payAmount == 0) return;
        if (payCurrency == address(0)) {
            // native token
            require(msg.value >= payAmount, "Insufficient payment amount");
            payable(feeRecipient).transfer(msg.value);
        } else {
            // erc20 token
            SafeERC20.safeTransferFrom(
                IERC20(payCurrency),
                msg.sender,
                feeRecipient,
                payAmount
            );
        }
    }
}
