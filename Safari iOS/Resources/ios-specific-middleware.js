/*
 * ATTENTION: The "eval" devtool has been used (maybe by default in mode: "development").
 * This devtool is neither made for production nor for readable output files.
 * It uses "eval()" calls to create a separate source file in the browser devtools.
 * If you are trying to read the output file, select a different devtool (https://webpack.js.org/configuration/devtool/)
 * or disable the default devtool with "devtool: false".
 * If you are looking for production-ready output files, see mode: "production" (https://webpack.js.org/configuration/mode/).
 */
/******/ (() => { // webpackBootstrap
/******/ 	var __webpack_modules__ = ({

/***/ "./src/ios-middleware.js":
/*!*******************************!*\
  !*** ./src/ios-middleware.js ***!
  \*******************************/
/***/ (() => {

eval("function startBar() {\n    window.ethereum.address !== `` && (updateBar());\n\n    window.ethereum.on(`accountsChanged`, () => {\n        updateBar();\n    });\n}\n\nfunction updateBar() {\n    window.ethereum.request({ method: `eth_requestAccounts` }).then((result) => {\n        const xhr = new XMLHttpRequest();\n        xhr.onload = () => {\n            const res = xhr.response;\n            const json = JSON.parse(res);\n            window.postMessage({direction: `from-middleware-script`, subject: `updateBar`, message: JSON.stringify({ address: result[0], balance: json.result, })}, `*`);\n        }\n        xhr.onerror = () => {\n            console.log(`Request failed.`);\n        };\n        xhr.open(`POST`, window.ethereum.rpc.rpcUrl, true);\n        xhr.setRequestHeader(`Content-Type`, `application/json`);\n        xhr.send(JSON.stringify({\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\": [result[0], \"latest\"],\"id\":1}));\n    });\n}\n\nif (typeof window.ethereum !== `undefined`) {\n    startBar();\n} else {\n    const interval = setInterval(() => {\n        if (typeof window.ethereum !== `undefined`) {\n            clearInterval(interval);\n            startBar();\n        }\n    }, 1000);\n}\n\n\n//# sourceURL=webpack://Balance-extension-iOS/./src/ios-middleware.js?");

/***/ })

/******/ 	});
/************************************************************************/
/******/ 	
/******/ 	// startup
/******/ 	// Load entry module and return exports
/******/ 	// This entry module can't be inlined because the eval devtool is used.
/******/ 	var __webpack_exports__ = {};
/******/ 	__webpack_modules__["./src/ios-middleware.js"]();
/******/ 	
/******/ })()
;