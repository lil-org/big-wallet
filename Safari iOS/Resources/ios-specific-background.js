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

/***/ "./src/ios-background.js":
/*!*******************************!*\
  !*** ./src/ios-background.js ***!
  \*******************************/
/***/ (() => {

eval("function didMakeRequest(requestId, tabId) {\n    pendingTabIds[requestId] = tabId;\n}\n\nfunction didCompleteRequest(id) {\n    const request = { id: id, subject: \"didCompleteRequest\" };\n    browser.runtime.sendNativeMessage(\"io.balance\", request);\n}\n\nconsole.log('test');\n\n\n//# sourceURL=webpack://Balance-extension-iOS/./src/ios-background.js?");

/***/ })

/******/ 	});
/************************************************************************/
/******/ 	
/******/ 	// startup
/******/ 	// Load entry module and return exports
/******/ 	// This entry module can't be inlined because the eval devtool is used.
/******/ 	var __webpack_exports__ = {};
/******/ 	__webpack_modules__["./src/ios-background.js"]();
/******/ 	
/******/ })()
;