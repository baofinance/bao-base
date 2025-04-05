module.exports = {
    printWidth: 120,
    useTabs: false,
    tabWidth: 4,
    overrides: [
        {
            files: "*.sol",
            options: {
                semi: true,
                singleQuote: false,
                trailingComma: "all",
            },
        },
        {
            files: ["*.ts", "*.tsx"],
            options: {
                arrowParens: "avoid",
                explicitTypes: "preserve",
                semi: true,
                singleQuote: true,
                trailingComma: "all",
            },
        },
        {
            files: ["*.yml", "*.yaml"],
            options: {
                parser: "yaml",
                tabWidth: 2,
            },
        },
        {
            files: ["*.sh", "*.bash"],
            options: {
                parser: "sh",
            },
        },
        {
            // Match any file with bash shebang
            files: ["*"],
            pattern: "^#!/.*bash.*",
            options: {
                parser: "sh",
            },
        },
    ],
    plugins: ["prettier-plugin-solidity", "prettier-plugin-sh"],
};
