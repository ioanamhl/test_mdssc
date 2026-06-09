const express = require('express');
const cors = require('cors');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3001;

app.use(cors());
app.use(express.json());

let todos = [
  { id: 1, text: 'Learn MDSSC Pipeline', done: false },
  { id: 2, text: 'Test Jenkins integration', done: false },
];
let nextId = 3;

app.get('/api/todos', (req, res) => res.json(todos));

app.post('/api/todos', (req, res) => {
  const { text } = req.body;
  if (!text || !text.trim()) return res.status(400).json({ error: 'text required' });
  const todo = { id: nextId++, text: text.trim(), done: false };
  todos.push(todo);
  res.status(201).json(todo);
});

app.patch('/api/todos/:id', (req, res) => {
  const todo = todos.find(t => t.id === Number(req.params.id));
  if (!todo) return res.status(404).json({ error: 'Not found' });
  if (req.body.done !== undefined) todo.done = Boolean(req.body.done);
  if (req.body.text !== undefined) todo.text = req.body.text;
  res.json(todo);
});

app.delete('/api/todos/:id', (req, res) => {
  todos = todos.filter(t => t.id !== Number(req.params.id));
  res.status(204).end();
});

// Serve built frontend
const buildPath = path.join(__dirname, '..', 'frontend', 'build');
app.use(express.static(buildPath));
app.get('*', (req, res) => res.sendFile(path.join(buildPath, 'index.html')));

app.listen(PORT, () => console.log(`Server on port ${PORT}`));
