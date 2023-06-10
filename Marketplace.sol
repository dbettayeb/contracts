// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/interfaces/IERC165.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "./IERC4907.sol";

contract Marketplace is ReentrancyGuard {
    using Counters for Counters.Counter;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;
    Counters.Counter private _nftsListed;
    Counters.Counter private _nftsRented;

    function getcurrentid() public view returns (uint256) {
        return _nftsListed.current();
    }

    address private _marketOwner;
    uint256 private _listingFee = .01 ether;
    uint256 currentid;
    // maps contract address to token id to properties of the rental listing
    mapping(address => mapping(uint256 => Listing)) private _listingMap;
    mapping(address => mapping(uint256 => Listing)) private _rentingMap;

    // maps nft contracts to set of the tokens that are listed
    mapping(address => EnumerableSet.UintSet) private _nftContractTokensMap;
    // tracks the nft contracts that have been listed
    EnumerableSet.AddressSet private _nftContracts;
    struct Listing {
        address owner;
        address user;
        address nftContract;
        uint256 tokenId;
        uint256 price;
        uint256 expires; // when the user can no longer rent it
        string mac;
        string state;
    }
    event NFTListed(
        address owner,
        address user,
        address nftContract,
        uint256 tokenId,
        uint256 price,
        uint256 expires,
        string mac,
        string state
    );
    event NFTRented(
        address owner,
        address user,
        address nftContract,
        uint256 tokenId,
        uint64 expires,
        uint256 price,
        string mac,
        string state
    );
    event NFTUnlisted(
        address unlistSender,
        address nftContract,
        uint256 tokenId,
        uint256 refund
    );

    constructor() {
        _marketOwner = msg.sender;
    }

    function compareStrings(
        string memory a,
        string memory b
    ) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }

    // function to list NFT for rental
    function listNFT(
        address nftContract,
        uint256 tokenId,
        uint256 price
    ) public payable nonReentrant {
        require(isRentableNFT(nftContract), "Contract is not an ERC4907");
        require(
            IERC721(nftContract).ownerOf(tokenId) == msg.sender,
            "Not owner of nft"
        );
        require(msg.value == _listingFee, "Not enough ether for listing fee");
        require(price > 0, "Rental price should be greater than 0");
        require(
            _listingMap[nftContract][tokenId].nftContract == address(0),
            "This NFT has already been listed"
        );

        payable(_marketOwner).transfer(_listingFee);
        _listingMap[nftContract][tokenId] = Listing(
            msg.sender,
            address(0),
            nftContract,
            tokenId,
            price,
            0,
            "",
            "Not rented yet"
        );
        _nftsListed.increment();
        EnumerableSet.add(_nftContractTokensMap[nftContract], tokenId);
        EnumerableSet.add(_nftContracts, nftContract);
        emit NFTListed(
            IERC721(nftContract).ownerOf(tokenId),
            address(0),
            nftContract,
            tokenId,
            price,
            0,
            "",
            "Not rented yet"
        );
    }

    function getListedTokenForId(
        address nftcontract,
        uint256 tokenId
    ) public view returns (Listing memory) {
        return _listingMap[nftcontract][tokenId];
    }

    function isRentableNFT(address nftContract) public view returns (bool) {
        bool _isRentable = false;
        bool _isNFT = false;
        try
            IERC165(nftContract).supportsInterface(type(IERC4907).interfaceId)
        returns (bool rentable) {
            _isRentable = rentable;
        } catch {
            return false;
        }
        try
            IERC165(nftContract).supportsInterface(type(IERC721).interfaceId)
        returns (bool nft) {
            _isNFT = nft;
        } catch {
            return false;
        }
        return _isRentable && _isNFT;
    }

    // function to rent an NFT
    function rentNFT(
        address nftContract,
        uint256 tokenId,
        uint256 price,
        uint64 expires,
        string memory mac
    ) public payable nonReentrant {
        Listing storage listing = _listingMap[nftContract][tokenId];
        require(
            listing.user == address(0) || block.timestamp > listing.expires,
            "NFT already rented"
        );
        // Transfer rental fee
        require(msg.value >= price, "Not enough ether to cover rental period");
        payable(listing.owner).transfer(price);
        // Update listing
        IERC4907(nftContract).setUser(tokenId, msg.sender, expires, mac);
        listing.user = msg.sender;
        listing.expires = expires;
        listing.mac = mac;

        _listingMap[nftContract][tokenId] = Listing(
            IERC721(nftContract).ownerOf(tokenId),
            listing.user,
            nftContract,
            tokenId,
            price,
            expires,
            listing.mac,
            "Rented"
        );
        _rentingMap[nftContract][tokenId] = Listing(
            IERC721(nftContract).ownerOf(tokenId),
            listing.user,
            nftContract,
            tokenId,
            price,
            expires,
            listing.mac,
            "Rented"
        );
        _nftsRented.increment();

        emit NFTRented(
            IERC721(nftContract).ownerOf(tokenId),
            msg.sender,
            nftContract,
            tokenId,
            expires,
            price,
            listing.mac,
            "Rented"
        );
    }

    function updateExpiredListings() public {
        address[] memory nftContracts = EnumerableSet.values(_nftContracts);
        for (uint i = 0; i < nftContracts.length; i++) {
            address nftAddress = nftContracts[i];
            uint256[] memory tokens = EnumerableSet.values(
                _nftContractTokensMap[nftAddress]
            );
            for (uint j = 0; j < tokens.length; j++) {
                uint256 tokenId = tokens[j];
                Listing storage listing = _listingMap[nftAddress][tokenId];
                if (listing.expires < block.timestamp) {
                    // Update listing to initial state
                    listing.user = address(0);
                    listing.expires = 0;
                    listing.mac = "";
                    listing.state = "Not rented yet";
                }
            }
        }
    }

    // function to unlist your rental, refunding the user for any lost time
    function unlistNFT(
        address nftContract,
        uint256 tokenId
    ) public payable nonReentrant {
        Listing storage listing = _listingMap[nftContract][tokenId];
        require(listing.owner != address(0), "This NFT is not listed");
        require(
            listing.owner == msg.sender || _marketOwner == msg.sender,
            "Not approved to unlist NFT"
        );
        // fee to be returned to user if unlisted before rental period is up
        // nothing to refund if no renter
        uint256 refund = 0;
        if (listing.user != address(0)) {
            refund = listing.price;
            require(msg.value >= refund, "Not enough ether to cover refund");
            payable(listing.user).transfer(refund);
        }
        // clean up data
        IERC4907(nftContract).setUser(tokenId, address(0), 0, "");
        EnumerableSet.remove(_nftContractTokensMap[nftContract], tokenId);
        delete _listingMap[nftContract][tokenId];
        if (EnumerableSet.length(_nftContractTokensMap[nftContract]) == 0) {
            EnumerableSet.remove(_nftContracts, nftContract);
        }
        _nftsListed.decrement();

        emit NFTUnlisted(msg.sender, nftContract, tokenId, refund);
    }

    /*
     * function to get all listings
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function getAllListings() public view returns (Listing[] memory) {
        Listing[] memory listings = new Listing[](_nftsListed.current());
        uint256 listingsIndex = 0;
        address[] memory nftContracts = EnumerableSet.values(_nftContracts);
        for (uint i = 0; i < nftContracts.length; i++) {
            address nftAddress = nftContracts[i];
            uint256[] memory tokens = EnumerableSet.values(
                _nftContractTokensMap[nftAddress]
            );
            for (uint j = 0; j < tokens.length; j++) {
                listings[listingsIndex] = _listingMap[nftAddress][tokens[j]];
                listingsIndex++;
            }
        }
        return listings;
    }

    function getAllListingsByAddress(
        address account
    ) public view returns (Listing[] memory) {
        Listing[] memory listings = new Listing[](_nftsListed.current());
        uint256 listingsIndex = 0;
        address[] memory nftContracts = EnumerableSet.values(_nftContracts);

        for (uint i = 0; i < nftContracts.length; i++) {
            address nftAddress = nftContracts[i];
            uint256[] memory tokens = EnumerableSet.values(
                _nftContractTokensMap[nftAddress]
            );

            for (uint j = 0; j < tokens.length; j++) {
                if (_listingMap[nftAddress][tokens[j]].owner == account) {
                    listings[listingsIndex] = _listingMap[nftAddress][
                        tokens[j]
                    ];
                    listingsIndex++;
                }
            }
        }

        // Create a new array to store only the non-zero values
        Listing[] memory ownedListings = new Listing[](listingsIndex);
        for (uint k = 0; k < listingsIndex; k++) {
            ownedListings[k] = listings[k];
        }

        return ownedListings;
    }

    function getAllRented() public view returns (Listing[] memory) {
        Listing[] memory listings = new Listing[](_nftsListed.current());
        uint256 listingsIndex = 0;
        address[] memory nftContracts = EnumerableSet.values(_nftContracts);
        for (uint i = 0; i < nftContracts.length; i++) {
            address nftAddress = nftContracts[i];
            uint256[] memory tokens = EnumerableSet.values(
                _nftContractTokensMap[nftAddress]
            );
            for (uint j = 0; j < tokens.length; j++) {
                if (
                    compareStrings(
                        _listingMap[nftAddress][tokens[j]].state,
                        "Rented"
                    )
                ) {
                    listings[listingsIndex] = _listingMap[nftAddress][
                        tokens[j]
                    ];
                    listingsIndex++;
                }
            }
        }
        Listing[] memory rentedListings = new Listing[](listingsIndex);
        for (uint k = 0; k < listingsIndex; k++) {
            rentedListings[k] = listings[k];
        }

        return rentedListings;
    }

    function getAllnotRented() public view returns (Listing[] memory) {
        Listing[] memory listings = new Listing[](_nftsListed.current());
        uint256 listingsIndex = 0;
        address[] memory nftContracts = EnumerableSet.values(_nftContracts);
        for (uint i = 0; i < nftContracts.length; i++) {
            address nftAddress = nftContracts[i];
            uint256[] memory tokens = EnumerableSet.values(
                _nftContractTokensMap[nftAddress]
            );
            for (uint j = 0; j < tokens.length; j++) {
                if (
                    compareStrings(
                        _listingMap[nftAddress][tokens[j]].state,
                        "Not rented yet"
                    )
                ) {
                    listings[listingsIndex] = _listingMap[nftAddress][
                        tokens[j]
                    ];
                    listingsIndex++;
                }
            }
        }
        Listing[] memory notrentedListings = new Listing[](listingsIndex);
        for (uint k = 0; k < listingsIndex; k++) {
            notrentedListings[k] = listings[k];
        }

        return notrentedListings;
    }

    function getListingFee() public view returns (uint256) {
        return _listingFee;
    }

    function getMyNFTs(
        address nftcontract
    ) public view returns (Listing[] memory) {
        uint totalItemCount = _nftsListed.current();
        uint itemCount = 0;
        uint currentIndex = 0;
        uint currentId;
        //Important to get a count of all the NFTs that belong to the user before we can make an array for them
        for (uint i = 0; i < totalItemCount; i++) {
            if (_listingMap[nftcontract][i + 1].owner == msg.sender) {
                itemCount += 1;
            }
        }
        //Once you have the count of relevant NFTs, create an array then store all the NFTs in it
        Listing[] memory items = new Listing[](itemCount);
        for (uint i = 0; i < totalItemCount; i++) {
            if (_listingMap[nftcontract][i + 1].owner == msg.sender) {
                currentId = i + 1;
                Listing storage currentItem = _listingMap[nftcontract][
                    currentId
                ];
                items[currentIndex] = currentItem;
                currentIndex += 1;
            }
        }
        return items;
    }

    function getMyrentedNFTs(
        address nftcontract
    ) public view returns (Listing[] memory) {
        uint totalItemCount = _nftsRented.current();
        uint itemCount = 0;
        uint currentIndex = 0;
        uint currentId;
        //Important to get a count of all the NFTs that belong to the user before we can make an array for them
        for (uint i = 0; i < totalItemCount; i++) {
            if (_rentingMap[nftcontract][i + 1].user == msg.sender) {
                itemCount += 1;
            }
        }
        //Once you have the count of relevant NFTs, create an array then store all the NFTs in it
        Listing[] memory items = new Listing[](itemCount);
        for (uint i = 0; i < totalItemCount; i++) {
            if (_rentingMap[nftcontract][i + 1].user == msg.sender) {
                currentId = i + 1;
                Listing storage currentItem = _rentingMap[nftcontract][
                    currentId
                ];
                items[currentIndex] = currentItem;
                currentIndex += 1;
            }
        }
        return items;
    }
}
