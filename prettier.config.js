module.exports = {
    printWidth: 120,
    useTabs: false,
    tabWidth: 2,
    overrides: [
      {
        files: "*.sol",
        options: {
          semi: true,
          singleQuote: false,
          trailingComma: "all",
          tabWidth: 4,
        }
      },
      {
        files: [
          "*.ts", "*.tsx"
        ],
        options: {
          arrowParens: "avoid",
          explicitTypes: "preserve",
          semi: true,
          singleQuote: true,
          trailingComma: "all",
          tabWidth: 4,
        }
      },
      {
        files: [
          "*.yml", "*.yaml"
        ],
        options: {
          parser: "yaml"
        }
      }
    ],
    plugins: [
      "prettier-plugin-solidity"
    ]
  };