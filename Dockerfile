FROM --platform=linux/amd64 node:16.13.2-alpine

ENV NODE_ENV prod

WORKDIR /usr/src/app

EXPOSE 3000

COPY package*.json ./

RUN npm install

COPY . .

RUN npm run build

CMD ["npm", "run", "start:prod"]