const mix = require('laravel-mix');
const webpack = require('webpack');
const TerserPlugin = require('terser-webpack-plugin');

const buildDate = new Date().toISOString().split('T')[0];

// Base webpack configuration shared by both dev and prod
const baseConfig = {
    module: {
        rules: [
            {
                test: /\.js$/,
                type: 'javascript/auto'
            }
        ]
    },
    plugins: [
        new webpack.ProvidePlugin({
            $: 'jquery',
            jQuery: 'jquery',
            'window.jQuery': 'jquery'
        })
    ]
};

if (mix.inProduction()) {
    // ────────────────────────────────────
    //  PRODUCTION BUILD
    // ────────────────────────────────────
    baseConfig.plugins.push(
        new webpack.BannerPlugin(`DSTACK PANEL - PRODUCTION BUILD - ${buildDate}`)
    );

    baseConfig.optimization = {
        minimizer: [
            new TerserPlugin({
                terserOptions: {
                    compress: {
                        drop_console: true,
                        drop_debugger: true,
                    },
                },
            }),
        ],
    };

    mix.version();
} else {
    // ────────────────────────────────────
    //  DEVELOPMENT BUILD
    // ────────────────────────────────────
    mix.sourceMaps();

    baseConfig.plugins.push(
        new webpack.BannerPlugin(`DSTACK PANEL - DEVELOPMENT BUILD - ${buildDate}`)
    );
}

mix.postCss('resources/css/app.css', 'public/assets/css')
   .js('resources/js/app.js', 'public/assets/js')
   .webpackConfig(baseConfig);
