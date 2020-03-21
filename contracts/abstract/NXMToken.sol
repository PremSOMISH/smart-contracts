pragma solidity ^0.5.16;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract NXMToken is IERC20 {

  function burn(uint256 amount) public returns (bool);

  function burnFrom(address from, uint256 value) public returns (bool);
}