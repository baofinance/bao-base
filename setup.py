from setuptools import setup, find_packages

setup(
    name="bao-base",
    version="0.1.0",
    packages=find_packages(),
    python_requires=">=3.7",
    install_requires=[
        "pytest>=7.0.0",
        "python-dotenv"
    ],
)
