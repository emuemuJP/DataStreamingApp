FROM --platform=linux/amd64 node:20-bullseye

WORKDIR /app

ENV SKIP_CMAKE_CHECK=1

COPY package.json package-lock.json* ./
COPY scripts ./scripts
RUN npm install

COPY server.js ./
COPY client ./client

EXPOSE 8080
CMD ["node", "server.js"]
