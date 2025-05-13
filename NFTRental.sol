// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title Advanced NFT Rental Marketplace
 * @dev A decentralized platform for renting out NFTs with flexible terms
 * @notice This contract allows NFT owners to list their assets for rent and renters to use them for a specified period
 */
contract NFTRental is IERC721Receiver, ReentrancyGuard {
    using SafeMath for uint256;
    using Counters for Counters.Counter;

    Counters.Counter private _rentalIdCounter;

    // Rental status enum
    enum RentalStatus {
        LISTED,
        RENTED,
        COMPLETED,
        CANCELLED
    }

    // Rental structure
    struct Rental {
        uint256 rentalId;
        address nftContract;
        uint256 tokenId;
        address owner;
        address renter;
        uint256 startTime;
        uint256 endTime;
        uint256 pricePerDay;
        uint256 collateral;
        RentalStatus status;
        bool isActive;
    }

    // Mapping from rental ID to Rental
    mapping(uint256 => Rental) public rentals;

    // Mapping from NFT contract to token ID to active rental ID
    mapping(address => mapping(uint256 => uint256)) public activeRentals;

    // Mapping from user address to their rental IDs
    mapping(address => uint256[]) public userRentals;

    // Platform fee percentage (1% = 100)
    uint256 public platformFeePercentage = 500; // 5%

    // Platform fee collector address
    address public feeCollector;

    // Events
    event RentalListed(
        uint256 indexed rentalId,
        address indexed nftContract,
        uint256 indexed tokenId,
        address owner,
        uint256 pricePerDay,
        uint256 collateral,
        uint256 minDuration,
        uint256 maxDuration
    );
    event RentalStarted(
        uint256 indexed rentalId,
        address indexed renter,
        uint256 startTime,
        uint256 endTime,
        uint256 totalPrice
    );
    event RentalCompleted(uint256 indexed rentalId);
    event RentalCancelled(uint256 indexed rentalId);
    event NFTClaimed(uint256 indexed rentalId, address indexed claimer);
    event PlatformFeeUpdated(uint256 newFee);
    event FeeCollectorUpdated(address newCollector);

    constructor(address _feeCollector) {
        feeCollector = _feeCollector;
    }

    /**
     * @dev List an NFT for rent
     * @param nftContract Address of the NFT contract
     * @param tokenId ID of the NFT token
     * @param pricePerDay Rental price per day in wei
     * @param collateral Required collateral amount in wei
     * @param minDuration Minimum rental duration in days
     * @param maxDuration Maximum rental duration in days
     */
    function listNFTForRent(
        address nftContract,
        uint256 tokenId,
        uint256 pricePerDay,
        uint256 collateral,
        uint256 minDuration,
        uint256 maxDuration
    ) external nonReentrant {
        require(pricePerDay > 0, "Price must be greater than 0");
        require(collateral >= pricePerDay.mul(7), "Collateral must cover at least 7 days");
        require(minDuration > 0, "Minimum duration must be at least 1 day");
        require(maxDuration >= minDuration, "Max duration must be >= min duration");

        // Check if the caller owns the NFT
        IERC721 nft = IERC721(nftContract);
        require(nft.ownerOf(tokenId) == msg.sender, "Caller is not the owner");

        // Check if there's no active rental for this NFT
        require(activeRentals[nftContract][tokenId] == 0, "NFT is already listed for rent");

        // Transfer NFT to this contract
        nft.safeTransferFrom(msg.sender, address(this), tokenId);

        // Create new rental
        _rentalIdCounter.increment();
        uint256 rentalId = _rentalIdCounter.current();

        rentals[rentalId] = Rental({
            rentalId: rentalId,
            nftContract: nftContract,
            tokenId: tokenId,
            owner: msg.sender,
            renter: address(0),
            startTime: 0,
            endTime: 0,
            pricePerDay: pricePerDay,
            collateral: collateral,
            status: RentalStatus.LISTED,
            isActive: true
        });

        activeRentals[nftContract][tokenId] = rentalId;
        userRentals[msg.sender].push(rentalId);

        emit RentalListed(
            rentalId,
            nftContract,
            tokenId,
            msg.sender,
            pricePerDay,
            collateral,
            minDuration,
            maxDuration
        );
    }

    /**
     * @dev Rent an NFT
     * @param rentalId ID of the rental to start
     * @param duration Duration of the rental in days
     */
    function rentNFT(uint256 rentalId, uint256 duration) external payable nonReentrant {
        Rental storage rental = rentals[rentalId];
        require(rental.isActive, "Rental does not exist");
        require(rental.status == RentalStatus.LISTED, "NFT is not available for rent");
        require(duration > 0, "Duration must be at least 1 day");

        uint256 totalPrice = rental.pricePerDay.mul(duration);
        uint256 totalAmount = totalPrice.add(rental.collateral);
        require(msg.value >= totalAmount, "Insufficient payment");

        // Calculate rental period
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime.add(duration.mul(1 days));

        // Update rental details
        rental.renter = msg.sender;
        rental.startTime = startTime;
        rental.endTime = endTime;
        rental.status = RentalStatus.RENTED;

        // Transfer NFT to renter
        IERC721(rental.nftContract).safeTransferFrom(address(this), msg.sender, rental.tokenId);

        // Calculate and transfer platform fee
        uint256 platformFee = totalPrice.mul(platformFeePercentage).div(10000);
        uint256 ownerPayment = totalPrice.sub(platformFee);
        
        payable(rental.owner).transfer(ownerPayment);
        payable(feeCollector).transfer(platformFee);

        userRentals[msg.sender].push(rentalId);

        emit RentalStarted(rentalId, msg.sender, startTime, endTime, totalPrice);
    }

    /**
     * @dev Complete a rental and return the NFT
     * @param rentalId ID of the rental to complete
     */
    function completeRental(uint256 rentalId) external nonReentrant {
        Rental storage rental = rentals[rentalId];
        require(rental.isActive, "Rental does not exist");
        require(rental.status == RentalStatus.RENTED, "NFT is not currently rented");
        require(block.timestamp >= rental.endTime, "Rental period has not ended");

        // Return NFT to owner
        IERC721(rental.nftContract).safeTransferFrom(msg.sender, rental.owner, rental.tokenId);

        // Return collateral to renter
        payable(rental.renter).transfer(rental.collateral);

        // Update rental status
        rental.status = RentalStatus.COMPLETED;
        rental.isActive = false;
        activeRentals[rental.nftContract][rental.tokenId] = 0;

        emit RentalCompleted(rentalId);
    }

    /**
     * @dev Cancel a rental listing
     * @param rentalId ID of the rental to cancel
     */
    function cancelRental(uint256 rentalId) external nonReentrant {
        Rental storage rental = rentals[rentalId];
        require(rental.isActive, "Rental does not exist");
        require(rental.status == RentalStatus.LISTED, "Cannot cancel active rental");
        require(rental.owner == msg.sender, "Only owner can cancel");

        // Return NFT to owner
        IERC721(rental.nftContract).safeTransferFrom(address(this), rental.owner, rental.tokenId);

        // Update rental status
        rental.status = RentalStatus.CANCELLED;
        rental.isActive = false;
        activeRentals[rental.nftContract][rental.tokenId] = 0;

        emit RentalCancelled(rentalId);
    }

    /**
     * @dev Claim NFT after rental period (for owner if renter doesn't return)
     * @param rentalId ID of the rental to claim
     */
    function claimNFT(uint256 rentalId) external nonReentrant {
        Rental storage rental = rentals[rentalId];
        require(rental.isActive, "Rental does not exist");
        require(rental.status == RentalStatus.RENTED, "NFT is not currently rented");
        require(block.timestamp > rental.endTime, "Rental period has not ended");
        require(msg.sender == rental.owner, "Only owner can claim");

        // Transfer NFT back to owner
        IERC721(rental.nftContract).safeTransferFrom(rental.renter, rental.owner, rental.tokenId);

        // Keep collateral as penalty
        rental.status = RentalStatus.COMPLETED;
        rental.isActive = false;
        activeRentals[rental.nftContract][rental.tokenId] = 0;

        emit NFTClaimed(rentalId, msg.sender);
    }

    /**
     * @dev Update platform fee percentage
     * @param newFee New fee percentage (1% = 100)
     */
    function updatePlatformFee(uint256 newFee) external {
        require(msg.sender == feeCollector, "Only fee collector can update");
        require(newFee <= 2000, "Fee cannot exceed 20%");
        platformFeePercentage = newFee;
        emit PlatformFeeUpdated(newFee);
    }

    /**
     * @dev Update fee collector address
     * @param newCollector New fee collector address
     */
    function updateFeeCollector(address newCollector) external {
        require(msg.sender == feeCollector, "Only fee collector can update");
        require(newCollector != address(0), "Invalid address");
        feeCollector = newCollector;
        emit FeeCollectorUpdated(newCollector);
    }

    /**
     * @dev Get rentals by user
     * @param user Address of the user
     * @return Array of rental IDs
     */
    function getRentalsByUser(address user) external view returns (uint256[] memory) {
        return userRentals[user];
    }

    /**
     * @dev Get rental details by ID
     * @param rentalId ID of the rental
     * @return Rental details
     */
    function getRentalDetails(uint256 rentalId) external view returns (Rental memory) {
        return rentals[rentalId];
    }

    /**
     * @dev Required for ERC721 receiver
     */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
