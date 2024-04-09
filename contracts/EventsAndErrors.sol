// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface EventsAndErrors {
    ///////////// events //////////////////////
    event NFTUpgraded(
        address indexed user,
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        uint8 newLevel
    );
    event InitialMinted(
        address indexed user,
        uint256 indexed tokenId,
        uint8 level
    );
    event PublicMinted(
        address indexed user,
        uint256 indexed tokenId,
        uint8 level
    );
    event AdminMinted(
        address indexed user,
        uint256 indexed tokenId,
        uint8 level
    );
    event MainProfileSet(address indexed user, uint256 mainTokenId);
    ///////////// errors //////////////////////
}
