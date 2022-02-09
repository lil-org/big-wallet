module.exports = {
    mode: "development",
    entry: {
       middleware: "./src/ios-middleware.js",
       background: "./src/ios-background.js",
       content: "./src/ios-content.js"
    },
    output: {
        filename: 'ios-specific-[name].js',
        path: __dirname + '/Resources',
    },
};
