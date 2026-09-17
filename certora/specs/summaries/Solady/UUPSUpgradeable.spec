// Summarization of UUPS upgrade functions
// UUPS upgradeToAndCall contains complex assembly that is difficult to verify
// We NONDET it to skip the low-level implementation details and focus on business logic

methods {
    function _.upgradeToAndCall(address, bytes calldata) internal => NONDET;
}
