FROM --platform=linux/amd64 node:16.13.2-alpine

ENV NODE_ENV prod

USER node

WORKDIR /usr/src/app

EXPOSE 3000

COPY --chown=node:node package*.json ./

RUN npm install

COPY --chown=node:node . .

RUN npm run build

CMD ["npm", "run", "start:prod"]