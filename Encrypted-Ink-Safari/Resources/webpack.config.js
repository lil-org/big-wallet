const path = require("path");
const TerserPlugin = require("terser-webpack-plugin");

module.exports = {
  mode: "production",
  entry: "./src/provider.js",
  optimization: {
    minimizer: [
      new TerserPlugin({
        terserOptions: { keep_classnames: true, keep_fnames: true },
      }),
    ],
  },
  performance: {
    hints: false,
  },
  output: {
    filename: "provider.js",
    path: path.resolve(__dirname, "dist"),
  },
};
