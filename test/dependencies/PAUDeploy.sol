// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

interface IPAUFactoryLike {

    function deployAccessControls(address admin) external returns (address accessControls);

    function deployALMProxy(address admin) external returns (address almProxy);

    function deployController(address accessControls, address proxy, address rateLimits)
        external
        returns (address controller);

    function deployRateLimits(address admin) external returns (address rateLimits);

}

/**
 * @param pauFactory The canonical on-chain PAUFactory used to deploy each component.
 * @param owner      Sole DEFAULT_ADMIN_ROLE holder after deployment — the relevant governance
 *                   contract (PauseProxy or SubProxy).
 */
struct PAUDeployParams {
    address pauFactory;
    address owner;
}

/**
 * @title  PAUDeploy
 * @notice Deployment library for a PAU stack. Deployment-only by design: the only wiring
 *         performed here is through immutable constructor parameters (the Controller's
 *         AccessControls / ALMProxy / RateLimits references). Each component is deployed with
 *         `owner` as its sole DEFAULT_ADMIN_ROLE holder and the deployer never holds any role,
 *         so there is nothing to revoke.
 *
 *         All mutable configuration — CONTROLLER grants, integrations, allocator roles, actors,
 *         and any other role setting — is done by the spell through the component repos' init
 *         libraries (PAUInit, AdministeredAgentInit), built from this deployment's exported
 *         addresses. Plain addresses are returned so no struct is shared across repos.
 */
library PAUDeploy {

    /**
     * @notice Deploys a full PAU stack (ALMProxy + AccessControls + RateLimits + Controller).
     * @param  p              Deployment parameters.
     * @return accessControls The deployed AccessControls.
     * @return almProxy       The deployed ALMProxy.
     * @return rateLimits     The deployed RateLimits.
     * @return controller     The deployed Controller.
     */
    function deploy(PAUDeployParams memory p)
        internal
        returns (address accessControls, address almProxy, address rateLimits, address controller)
    {
        require(p.pauFactory != address(0), "PAUDeploy/pau-factory-zero-address");
        require(p.owner      != address(0), "PAUDeploy/owner-zero-address");

        almProxy = IPAUFactoryLike(p.pauFactory).deployALMProxy(p.owner);

        (accessControls, rateLimits, controller) = deployStack(p, almProxy);
    }

    /**
     * @notice Deploys an AccessControls / RateLimits / Controller stack against an existing
     *         ALMProxy. Shared-proxy systems deploy the proxy once (via {deploy}) and call this
     *         once per additional stack.
     * @param  p              Deployment parameters.
     * @param  almProxy       The existing ALMProxy the Controller is wired to.
     * @return accessControls The deployed AccessControls.
     * @return rateLimits     The deployed RateLimits.
     * @return controller     The deployed Controller.
     */
    function deployStack(PAUDeployParams memory p, address almProxy)
        internal
        returns (address accessControls, address rateLimits, address controller)
    {
        require(p.pauFactory != address(0), "PAUDeploy/pau-factory-zero-address");
        require(p.owner      != address(0), "PAUDeploy/owner-zero-address");
        require(almProxy     != address(0), "PAUDeploy/alm-proxy-zero-address");

        IPAUFactoryLike factory = IPAUFactoryLike(p.pauFactory);

        accessControls = factory.deployAccessControls(p.owner);
        rateLimits     = factory.deployRateLimits(p.owner);

        // The Controller's references are immutable constructor parameters — the only wiring
        // permitted at deployment time.
        controller = factory.deployController(accessControls, almProxy, rateLimits);
    }

}
