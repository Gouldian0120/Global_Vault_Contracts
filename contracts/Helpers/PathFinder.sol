// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "../Tokens/IPair.sol";
import "./IPathFinder.sol";
import '../Modifiers/Ownable.sol';
import './TokenAddresses.sol';
import 'hardhat/console.sol';

contract PathFinder is IPathFinder, Ownable {
    TokenAddresses public tokenAddresses;

    // relació de cada token amb el token que li fa d'intermediari per arribar a WBNB
    mapping (address => RouteInfo) public routeInfos;

    struct RouteInfo {
        bool directBNB;
        address tokenRoute;
    }

    constructor(
        address _tokenAddresses
    ) public {
        tokenAddresses = TokenAddresses(_tokenAddresses);
    }

    function addRouteInfoDirect(address _token) external onlyOwner override {
        routeInfos[_token].directBNB=true;
    }

    function addRouteInfoRoute(address _token, address _tokenRoute) external onlyOwner override {
        require(_tokenRoute!=address(0), 'PathFinder: you must define either a direct path to BNB or a routeToken to BNB');
        routeInfos[_token].tokenRoute=_tokenRoute;
    }

    function addRouteInfo(address _token, address _tokenRoute, bool _directBNB) external onlyOwner override {
        require(_tokenRoute!=address(0) || _directBNB, 'PathFinder: you must define either a direct path to BNB or a routeToken to BNB');

        routeInfos[_token].tokenRoute=_tokenRoute;
        routeInfos[_token].directBNB=_directBNB;
    }

    function removeRouteInfo(address _token) external onlyOwner override {
        delete routeInfos[_token];
    }

    function isTokenConnected(address _token) external view override returns (bool) {
        return routeInfos[_token].tokenRoute != address(0) || routeInfos[_token].directBNB;
    }

    function getRouteInfoTokenRoute(address _token) external view override returns (address) {
        return routeInfos[_token].tokenRoute;
    }

    function getRouteInfoDirectBNB(address _token) external view override returns (bool) {
        return routeInfos[_token].directBNB;
    }

    function getRouteInfo(address _token) internal view returns (RouteInfo memory) {
        return routeInfos[_token];
    }

    function findPath(address _tokenFrom, address _tokenTo) external view override returns (address[] memory)
    {
        RouteInfo memory infoFrom = getRouteInfo(_tokenFrom);
        RouteInfo memory infoTo = getRouteInfo(_tokenTo);
        address WBNB = tokenAddresses.findByName(tokenAddresses.BNB());

        address[] memory path;
        if ((_tokenFrom == WBNB && infoTo.directBNB) || (_tokenTo == WBNB && infoFrom.directBNB)) {
            // [WBNB, BUNNY] or [BUNNY, WBNB] casos en que no hi ha intermedi i un dels tokens es directament el WBNB
            path = new address[](2);
            path[0] = _tokenFrom;
            path[1] = _tokenTo;
        }
        else if ((infoFrom.tokenRoute != address(0)&&_tokenTo == WBNB)||(infoTo.tokenRoute != address(0) && _tokenFrom == WBNB)) {
            // [WBNB, BUSD, XXX] or [XXX, BUSD, WBNB] casos en que hi ha un intermig per arribar a WBNB i l'altre es directament WBNB
            path = new address[](3);
            path[0] = _tokenFrom;
            path[1] = infoFrom.tokenRoute != address(0)?infoFrom.tokenRoute:infoTo.tokenRoute;
            path[2] = _tokenTo;
        } else if (_tokenFrom == infoTo.tokenRoute || _tokenTo == infoFrom.tokenRoute) {
            // [VAI, BUSD] or [BUSD, VAI] casos en que directament l'intermedi de un dels tokens es l'altre token
            path = new address[](2);
            path[0] = _tokenFrom;
            path[1] = _tokenTo;
        } else if (infoFrom.tokenRoute != address(0) && infoFrom.tokenRoute == infoTo.tokenRoute) {
            // [VAI, DAI] or [VAI, USDC] casos en que l'intermedi es el mateix pels 2 tokens
            path = new address[](3);
            path[0] = _tokenFrom;
            path[1] = infoFrom.tokenRoute;
            path[2] = _tokenTo;
        } else if (infoFrom.directBNB && infoTo.directBNB) {
            // [USDT, BUNNY] or [BUNNY, USDT] casos en que no hi ha intermedi per cap dels tokens
            path = new address[](3);
            path[0] = _tokenFrom;
            path[1] = WBNB;
            path[2] = _tokenTo;
        } else if (infoFrom.tokenRoute != address(0) && infoTo.directBNB) {
            // [VAI, BUSD, WBNB, BUNNY] casos en que nomes el from te intermedi
            path = new address[](4);
            path[0] = _tokenFrom;
            path[1] = infoFrom.tokenRoute;
            path[2] = WBNB;
            path[3] = _tokenTo;
        } else if (infoTo.tokenRoute != address(0) && infoFrom.directBNB) {
            // [BUNNY, WBNB, BUSD, VAI] casos en que nomes el to te intermedi
            path = new address[](4);
            path[0] = _tokenFrom;
            path[1] = WBNB;
            path[2] = infoTo.tokenRoute;
            path[3] = _tokenTo;
        }  else if (infoFrom.tokenRoute != address(0) && infoTo.tokenRoute != address(0)) {
            // [VAI, BUSD, WBNB, xRoute, xToken] casos en que els 2 tenen intermedis
            path = new address[](5);
            path[0] = _tokenFrom;
            path[1] = infoFrom.tokenRoute;
            path[2] = WBNB;
            path[3] = infoTo.tokenRoute;
            path[4] = _tokenTo;
        }
        else
        {
            path = new address[](0);
        }
        return path;
    }
}