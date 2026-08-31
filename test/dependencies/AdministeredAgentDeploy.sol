// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

interface IAdministeredAgentFactoryLike {

    function deploy(address admin) external returns (address administeredAgent);

}

/**
 * @param agentFactory The canonical on-chain AdministeredAgentFactory.
 * @param owner        Sole admin of the agent after deployment — the relevant governance
 *                     contract (PauseProxy or SubProxy).
 */
struct AdministeredAgentDeployParams {
    address agentFactory;
    address owner;
}

/**
 * @title  AdministeredAgentDeploy
 * @notice Deployment library for an AdministeredAgent. Deployment-only by design: the agent is
 *         deployed with `owner` as its sole admin and the deployer never holds any role. All
 *         role configuration (actors, grantors, revokers, additional admins) and the
 *         ALLOCATOR_ROLE grant on the PAU AccessControls are done by the spell through
 *         {AdministeredAgentInit} and {PAUInit.addAllocator}.
 */
library AdministeredAgentDeploy {

    /**
     * @notice Deploys an AdministeredAgent owned by `p.owner`.
     * @param  p     Deployment parameters.
     * @return agent The deployed agent.
     */
    function deploy(AdministeredAgentDeployParams memory p) internal returns (address agent) {
        require(p.agentFactory != address(0), "AdministeredAgentDeploy/agent-factory-zero-address");
        require(p.owner        != address(0), "AdministeredAgentDeploy/owner-zero-address");

        agent = IAdministeredAgentFactoryLike(p.agentFactory).deploy(p.owner);
    }

}
